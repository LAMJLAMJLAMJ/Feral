#if os(macOS)
import AVFoundation
import FeralControl
import FeralIO
import FeralScene
import Foundation

/// The running engine: owns the render core, the audio device, the show and the control link, and
/// applies every change on its control queue. Nothing here runs on the audio thread.
final class Engine {
    let queue = DispatchQueue(label: "feral.control", qos: .userInteractive)
    /// Journal writes and saves, off the control queue.
    let housekeeping = DispatchQueue(label: "feral.housekeeping", qos: .utility)
    let options: Options
    let core: RenderCore
    private(set) var config: EngineConfig
    private var io: AudioEngineIO!
    private var timers: [DispatchSourceTimer] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var activity: NSObjectProtocol?
    private var spatial: SpatialRenderer?
    private var motionTimer: DispatchSourceTimer?
    private var motionStarted = Date()
    private var lastReport = (late: UInt64(0), overloads: 0, skipped: UInt64(0))

    // The show
    private var scene = ShowState(show: Show(name: "Untitled"))
    private var showURL: URL
    private var journal: Journal?
    private var pendingJournal: [JournalEntry] = []
    private var unsaved = 0
    private var seq = 0

    // Cues and fades
    private struct RunningFade {
        var fade: SnapshotFade
        let started: Date
        /// The cue to follow on from when it ends (an auto-follow cue).
        let followCue: UUID?
    }
    private var fades: [RunningFade] = []
    private var fadeTimer: DispatchSourceTimer?
    private var currentCue: UUID?

    // The control link
    private var server: ControlServer?
    private var clientNames: [ControlServer.ClientID: String] = [:]

    init(options: Options, config: EngineConfig) {
        self.options = options
        self.config = config
        core = RenderCore(sampleRate: config.sampleRate)
        showURL = ShowFile.url(for: config, configURL: options.configURL)
    }

    func start() {
        queue.async { [self] in
            log("feral-engine \(version) starting, pid \(getpid()), settings \(options.configURL.path)")
            // Keep the Mac awake and out of App Nap while the engine runs.
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical], reason: "Feral engine is rendering live audio")
            checkMicrophoneAccess()
            openShow()
            do { try publishLayout(fadeFrames: 0) } catch { log("error: \(error); playing silence until the show or settings are fixed") }
            applyTestSignal()
            io = AudioEngineIO(core: core, config: config, queue: queue, log: log)
            io.start()
            startControl()
            every(0.05) { [self] in core.collect() }
            every(0.1) { [self] in flushJournal() }
            every(10) { [self] in report(force: false) }
            every(300) { [self] in report(force: true) }
            onSignal(SIGHUP) { [self] in reload() }
            onSignal(SIGTERM) { [self] in shutdown("SIGTERM") }
            onSignal(SIGINT) { [self] in shutdown("SIGINT") }
        }
    }

    // MARK: - The show

    /// Opens engine.json's show and replays its journal. A show that does not exist yet is made from
    /// engine.json's speakers, groups and sources and saved there.
    private func openShow() {
        let opened: ShowFile.Opened
        do { opened = try ShowFile.open(for: config, configURL: options.configURL) } catch {
            log("error: cannot open the show: \(error). Playing an empty show; nothing is saved over it.")
            showURL = ShowFile.url(for: config, configURL: options.configURL)
            scene = ShowState(show: Show(name: "Unreadable show"))
            journal = nil
            return
        }
        showURL = opened.url
        scene = opened.state
        unsaved = opened.replayed
        currentCue = nil
        for p in opened.problems { log("show: \(p) (skipped)") }
        if !opened.exists {
            do {
                try ShowFile.save(scene, to: showURL)
                log("show: created \(showURL.path)"
                    + (config.speakers.isEmpty && config.sources.isEmpty ? "" : " from engine.json's speakers, groups and sources"))
            } catch { log("error: cannot create \(showURL.path): \(error)") }
        } else {
            log("show: \(scene.show.name) from \(showURL.path)"
                + (opened.replayed > 0 ? ", with \(opened.replayed) unsaved change(s) replayed from its journal" : ""))
            if !config.speakers.isEmpty || !config.groups.isEmpty || !config.sources.isEmpty {
                log("note: engine.json's speakers, groups and sources are ignored; the show has the layout "
                    + "(feral-cli show import makes a show from them)")
            }
        }
        journal = try? Journal(package: showURL)
        let s = scene
        log("show: \(s.system.speakers.count) speaker(s), \(s.show.groups.count) group(s), \(s.show.sources.count) source(s), "
            + "\(s.show.snapshots.count) snapshot(s), \(s.show.cues.count) cue(s)")
    }

    /// The engine's settings with the show's layout.
    private var renderConfig: EngineConfig { scene.engineConfig(base: config) }

    /// Publishes the show's layout (or, without groups, the fixed routing) as the next render state.
    private func publishLayout(fadeFrames: Int, quiet: Bool = false) throws {
        let config = renderConfig
        try config.validate()
        guard config.isSpatial else {
            stopMotion()
            spatial = nil
            let routing = try Routing(routes: config.routes, inputs: config.inputs, outputs: config.outputs)
            core.publish(routing)
            let routed = routing.gains.filter { $0 != 0 }.count
            if !quiet {
                log("routing: \(config.inputs) in by \(config.outputs) out, \(routed) gain(s) set"
                    + (config.routes.isEmpty ? " (passthrough)" : " from \(config.routes.count) route(s)"))
            }
            return
        }
        let renderer = try SpatialRenderer(config: config)
        let state = renderer.makeState()
        let taps = state.tapCount
        try core.publish(state, fadeFrames: fadeFrames)
        spatial = renderer
        guard !quiet else { return }
        log("spatial: \(config.speakers.count) speaker(s), \(config.sources.count) source(s), \(taps) tap(s)"
            + (config.routes.isEmpty ? "" : ", plus \(config.routes.count) fixed route(s)")
            + (fadeFrames > 0 ? "; crossfading over \(Int(config.groupCrossfadeMS)) ms" : ""))
        for line in renderer.groupSummaries { log("  group \(line)") }
        startMotion()
    }

    /// Applies a command to the show, updates what is heard, journals it and tells every client.
    private func apply(_ command: Command, origin: String, journaled: Bool = true) throws {
        var next = scene
        let change = try next.apply(command)
        switch change {
        case .none:
            scene = next
        case .sources(let ids):
            scene = next
            if let spatial {
                for id in ids {
                    guard let i = scene.sourceIndex(id), i < spatial.sources.count else { continue }
                    spatial.update(source: i, to: scene.sourceConfig(scene.show.sources[i]))
                }
                try core.publish(spatial.makeState())
            }
        case .layout(let crossfade):
            // Check the new layout renders before keeping it.
            let previous = scene
            scene = next
            do {
                try publishLayout(fadeFrames: crossfade ? config.groupCrossfadeFrames : 0, quiet: !crossfade)
            } catch {
                scene = previous
                throw error
            }
        }
        seq += 1
        if journaled {
            pendingJournal.append(JournalEntry(seq: seq, origin: origin, command: command))
            unsaved += 1
        }
        server?.broadcast(.applied(seq: seq, origin: origin, command: command))
    }

    /// Hands the journal entries so far to the housekeeping queue, which writes them.
    private func flushJournal() {
        guard !pendingJournal.isEmpty else { return }
        let entries = JournalEntry.coalesce(pendingJournal)
        pendingJournal = []
        guard let journal else { return }
        housekeeping.async {
            do { try journal.append(entries) } catch { log("error: cannot write the journal: \(error)") }
        }
    }

    /// Saves the show and empties its journal.
    private func save() throws {
        guard journal != nil else { throw ConfigError("the show could not be opened, so it is not saved over") }
        flushJournal()
        let state = scene
        let url = showURL
        var failure: Error?
        housekeeping.sync {
            do {
                try ShowFile.save(state, to: url)
                journal?.reopen()
            } catch { failure = error }
        }
        if let failure { throw failure }
        unsaved = 0
        log("show: saved \(url.path)")
        broadcastStatus()
    }

    // MARK: - Cues and fades

    private func recall(_ snapshot: Snapshot, seconds: Double?, curve: FadeCurve?, followCue: UUID?) {
        let fade = SnapshotFade(snapshot: snapshot, state: scene, seconds: seconds, curve: curve)
        // The new fade takes over its sources from any fade still running.
        let taken = Set(fade.sources)
        for i in fades.indices { fades[i].fade.remove(taken) }
        fades.removeAll { $0.fade.parts.isEmpty && $0.followCue == nil }
        fades.append(RunningFade(fade: fade, started: Date(), followCue: followCue))
        stepFades()
        if !fades.isEmpty && fadeTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.stepFades() }
            timer.resume()
            fadeTimer = timer
        }
        broadcastStatus()
    }

    /// Moves every fading source to where it should be now; ends finished fades.
    private func stepFades() {
        let now = Date()
        var updates: [SourceUpdate] = []
        var finished: [RunningFade] = []
        for f in fades {
            let elapsed = now.timeIntervalSince(f.started)
            updates += f.fade.updates(at: elapsed)
            if f.fade.isFinished(at: elapsed) { finished.append(f) }
        }
        fades.removeAll { f in f.fade.isFinished(at: now.timeIntervalSince(f.started)) }
        if !updates.isEmpty {
            do { try apply(.updateSources(updates: updates), origin: "fade") } catch { log("fade: \(error)") }
        }
        if fades.isEmpty {
            fadeTimer?.cancel()
            fadeTimer = nil
        }
        guard !finished.isEmpty else { return }
        broadcastStatus()
        for f in finished where f.followCue != nil && f.followCue == currentCue {
            queue.async { [self] in
                do { try go(nil, origin: "auto-follow") } catch { log("cue: auto-follow: \(error)") }
            }
        }
    }

    private func stopFades() {
        fades = []
        fadeTimer?.cancel()
        fadeTimer = nil
        broadcastStatus()
    }

    /// Runs a cue (by number or id), or the next one.
    private func go(_ which: String?, origin: String) throws {
        let cue: Cue
        if let which {
            guard let c = scene.cue(matching: which) else { throw ConfigError("no cue \(which)") }
            cue = c
        } else {
            guard let c = scene.cue(after: currentCue) else { throw ConfigError("no cue after the current one") }
            cue = c
        }
        currentCue = cue.id
        let follow = cue.autoFollow ? cue.id : nil
        if let id = cue.snapshot, let snapshot = scene.snapshot(id) {
            let seconds = cue.fadeSeconds ?? snapshot.fadeSeconds
            log("cue \(cue.label) GO (\(origin)): snapshot \(snapshot.label) over \(seconds) s")
            recall(snapshot, seconds: cue.fadeSeconds, curve: cue.curve, followCue: follow)
        } else {
            log("cue \(cue.label) GO (\(origin))")
            broadcastStatus()
            if follow != nil {
                queue.async { [self] in
                    guard currentCue == cue.id else { return }
                    do { try go(nil, origin: "auto-follow") } catch { log("cue: auto-follow: \(error)") }
                }
            }
        }
    }

    // MARK: - The control link

    private func startControl() {
        let server = ControlServer(queue: queue)
        server.onLog = { log($0) }
        server.onConnect = { [weak self] id in
            guard let self else { return }
            server.send(.state(state: FullState(seq: seq, show: scene.show, system: scene.system, status: status)), to: id)
        }
        server.onDisconnect = { [weak self] id in
            guard let self else { return }
            if let name = clientNames.removeValue(forKey: id) { log("control: \(name) disconnected") }
        }
        server.onRequest = { [weak self] id, request in self?.handle(request, from: id) }
        do { try server.start(address: config.controlAddress, port: config.controlPort) } catch {
            log("error: the control link cannot listen on \(config.controlAddress) port \(config.controlPort): \(error)")
        }
        self.server = server
    }

    private func handle(_ request: Request, from client: ControlServer.ClientID) {
        let origin = clientNames[client] ?? "client \(client)"
        do {
            switch request {
            case .hello(let name):
                clientNames[client] = name
                log("control: \(name) connected")
            case .apply(let command):
                let touched = Set(command.touchedSources)
                if !touched.isEmpty {
                    for i in fades.indices { fades[i].fade.remove(touched) }
                }
                try apply(command, origin: origin)
                switch command {
                case .updateSources, .setSpeaker: break // too many while dragging
                default: log("\(origin): \(describe(command))")
                }
            case .recall(let which, let seconds):
                guard let snapshot = scene.snapshot(matching: which) else { throw ConfigError("no snapshot \(which)") }
                log("snapshot \(snapshot.label) recalled (\(origin)) over \(seconds ?? snapshot.fadeSeconds) s")
                recall(snapshot, seconds: seconds, curve: nil, followCue: nil)
            case .go(let which):
                try go(which, origin: origin)
            case .stopFades:
                stopFades()
            case .save:
                try save()
            case .refresh:
                server?.send(.state(state: FullState(seq: seq, show: scene.show, system: scene.system, status: status)), to: client)
            }
        } catch {
            server?.send(.error(message: "\(error)"), to: client)
        }
    }

    private var status: EngineStatus {
        let audio: String
        switch io?.state {
        case .running(let device)?: audio = "running on \(device)"
        case .waiting(let why)?: audio = "waiting: \(why)"
        default: audio = "stopped"
        }
        return EngineStatus(version: version, showPath: showURL.path, unsaved: unsaved, currentCue: currentCue,
                            nextCue: scene.cue(after: currentCue)?.id, fading: fades.flatMap { $0.fade.sources }, audio: audio)
    }

    private func broadcastStatus() { server?.broadcast(.status(status: status)) }

    private func describe(_ c: Command) -> String {
        switch c {
        case .updateSources(let u): return "moved \(u.count) source(s)"
        case .setSource(let s): return "set source \(s.label)"
        case .removeSource: return "removed a source"
        case .setSpeaker(let s): return "set speaker \(s.label)"
        case .removeSpeaker: return "removed a speaker"
        case .setGroup(let g): return "set group \(g.name)"
        case .removeGroup: return "removed a group"
        case .setLFESpeakers(let s): return "set \(s.count) LFE speaker(s)"
        case .captureSnapshot(let c): return "stored snapshot \(c.number) \(c.name)"
        case .setSnapshot(let s): return "set snapshot \(s.label)"
        case .removeSnapshot: return "removed a snapshot"
        case .setCue(let c): return "set cue \(c.label)"
        case .removeCue: return "removed a cue"
        case .renameShow(let n): return "renamed the show \(n)"
        }
    }

    // MARK: - Test motion

    /// Starts engine.json's test motion, if it names one of the show's sources.
    private func startMotion() {
        stopMotion()
        guard let motion = config.testMotion else { return }
        guard let source = scene.show.sources.first(where: { $0.input == motion.source }) else {
            log("test motion: no source uses input \(motion.source)")
            return
        }
        log("test motion: source \(source.label) moves on a \(motion.shape.rawValue), \(motion.seconds) s per round")
        motionStarted = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.stepMotion(motion, source: source.id) }
        timer.resume()
        motionTimer = timer
    }

    private func stopMotion() {
        motionTimer?.cancel()
        motionTimer = nil
    }

    /// Moves the test motion's source to where it should be now. Not journaled: it is a test.
    private func stepMotion(_ motion: TestMotion, source: UUID) {
        let p = motion.position(at: Date().timeIntervalSince(motionStarted))
        try? apply(.updateSources(updates: [SourceUpdate(id: source, values: SourceValues(position: p))]),
                   origin: "test motion", journaled: false)
    }

    private func applyTestSignal() {
        core.setTestSignal(config.testSignal, levelDB: config.testSignalDB, sineHz: config.testSignalHz)
        switch config.testSignal {
        case .off: break
        case .pink: log("test signal: pink noise at \(config.testSignalDB) dB RMS in place of input 1")
        case .sine: log("test signal: \(Int(config.testSignalHz)) Hz sine at \(config.testSignalDB) dB RMS in place of input 1")
        }
    }

    /// Re-reads engine.json. A routing change ramps in over one buffer; device changes reopen it; a
    /// different show is opened (the current one's changes stay in its journal).
    private func reload() {
        let newConfig: EngineConfig
        do { newConfig = try options.loadConfig() } catch {
            log("reload: \(error); keeping the current settings")
            return
        }
        let old = config
        config = newConfig
        if !old.sameDeviceSettings(as: newConfig) {
            if newConfig.sampleRate != old.sampleRate {
                log("reload: sampleRate changed; load figures use the old rate until the engine restarts")
            }
            io.reconfigure(newConfig)
        }
        if old.controlAddress != newConfig.controlAddress || old.controlPort != newConfig.controlPort {
            log("reload: the control link keeps \(old.controlAddress) port \(old.controlPort) until the engine restarts")
        }
        if ShowFile.url(for: newConfig, configURL: options.configURL) != showURL {
            flushJournal()
            housekeeping.sync {}
            stopFades()
            openShow()
            server?.broadcast(.state(state: FullState(seq: seq, show: scene.show, system: scene.system, status: status)))
        }
        // A layout change crossfades, so sources changing groups or renderers move over smoothly.
        do { try publishLayout(fadeFrames: newConfig.groupCrossfadeFrames) } catch { log("reload: \(error)") }
        if old.testSignal != .off && newConfig.testSignal == .off { log("test signal: off") }
        applyTestSignal()
    }

    private func shutdown(_ signal: String) {
        log("\(signal): stopping")
        flushJournal()
        housekeeping.sync {}
        server?.stop()
        io.stop()
        report(force: true)
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        exit(0)
    }

    /// Logs a warning when buffers ran late since the last check, or a status line when forced.
    private func report(force: Bool) {
        let s = core.stats(resetMaxLoad: true)
        let overloads = io.overloads
        let skipped = io.skippedBuffers
        let late = s.lateBuffers - min(lastReport.late, s.lateBuffers)
        let newOverloads = overloads - lastReport.overloads
        let newSkipped = skipped - min(lastReport.skipped, skipped)
        lastReport = (s.lateBuffers, overloads, skipped)
        let line = "buffers \(s.buffers), peak load \(Int((s.maxLoad * 100).rounded())) %, "
            + "late \(s.lateBuffers), overloads \(overloads), skipped \(skipped), "
            + "state #\(s.currentState) (\(core.liveStates) held), \(s.activeTaps) taps, faults \(io.faults), audio \(io.state)"
        if late > 0 || newOverloads > 0 || newSkipped > 0 {
            log("WARNING: in the last 10 s \(late) late, \(newOverloads) overload(s), \(newSkipped) skipped; \(line)")
        } else if force {
            log("status: \(line)")
        }
    }

    private func checkMicrophoneAccess() {
        guard config.inputs > 0 else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            log("asking macOS for audio input access")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                log(granted ? "audio input access granted"
                    : "audio input access denied: inputs will be silent. Allow Feral Engine in System Settings > Privacy & Security > Microphone")
            }
        default:
            log("WARNING: no audio input access, so inputs will be silent. Allow Feral Engine in "
                + "System Settings > Privacy & Security > Microphone")
        }
    }

    private func every(_ seconds: Double, _ action: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .milliseconds(Int(seconds * 100)))
        timer.setEventHandler(handler: action)
        timer.resume()
        timers.append(timer)
    }

    private func onSignal(_ number: Int32, _ action: @escaping () -> Void) {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
        source.setEventHandler(handler: action)
        source.resume()
        signalSources.append(source)
    }
}

func runOnMac(_ options: Options) -> Never {
    switch options.command {
    case "devices":
        do {
            let devices = try AudioDevices.all()
            for (n, d) in devices.enumerated() {
                let rates = d.availableSampleRates.map { "\(Int($0 / 1000))k" }.joined(separator: " ")
                print("\(n + 1). \(d.name)  [\(d.transport)]  in \(d.inputChannels), out \(d.outputChannels), "
                      + "\(Int(d.sampleRate)) Hz (\(rates))\(d.isAggregate ? "  AGGREGATE: not for live use" : "")")
                print("   UID: \(d.uid)")
            }
        } catch { fail("\(error)") }
        exit(0)
    case "run":
        let config: EngineConfig
        do { config = try options.loadConfig() } catch {
            // Exiting would make launchd restart us every second; wait for a fixed file instead.
            log("error: \(error). Fix \(options.configURL.path) and send SIGHUP, or restart the engine.")
            config = EngineConfig(device: nil)
        }
        let engine = Engine(options: options, config: config)
        engine.start()
        dispatchMain()
    default:
        fail("unknown command \(options.command); try --help")
    }
}
#endif

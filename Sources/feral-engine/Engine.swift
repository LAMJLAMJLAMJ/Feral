#if os(macOS)
import AVFoundation
import FeralControl
import FeralCore
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

    // OSC and MIDI
    /// Sources whose position OSC or tracking owns; the rest belong to cues.
    private var owners: [UUID: PositionOwner] = [:]
    private var osc: OSCServer?
    /// OSC subscribers, and whether each wants ADM-OSC.
    private var subscribers: [OSCServer.Peer: Bool] = [:]
    private var midiInput: MIDIInput?
    private var oscState = "off"
    private var midiState = "off"
    /// When each repeated OSC or MIDI problem was last logged, so a flood of one logs every 10 s.
    private var lastLogged: [String: Date] = [:]

    // Meters and the control monitor, for clients that asked (Request.watch)
    private struct Watch { var meters = false, activity = false }
    private var watchers: [ControlServer.ClientID: Watch] = [:]
    /// The input (from 1) each client wants the spectrum of, and the one the core's tap has now.
    private var analysers: [ControlServer.ClientID: Int] = [:]
    private var analysed: Int?
    /// OSC and MIDI received since the last `activity` event, and how many more were left out.
    private var heard: [ControlActivity] = []
    private var heardDropped = 0
    /// The most messages one `activity` event carries (it is sent every 0.1 s).
    private static let maxHeard = 100

    // The binaural monitor and what it hears
    private var listenSolo: [UUID] = []
    private var listenPFL: [UUID] = []
    private var monitorInfo = "off"
    /// What the monitor was last built from, so a change elsewhere does not rebuild it.
    private struct MonitorKey: Equatable {
        var settings: MonitorSettings?
        var speakers: [Speaker]
        var listener: Listener
        var sampleRate: Double
        var air: Double
        var outputs: Int
    }
    private var monitorKey: MonitorKey?
    private var hrirCache: (path: String, rate: Double, set: HRIRSet)?

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
            let workers = core.startWorkers(config.renderThreads ?? RenderCore.automaticWorkers)
            log("render: \(workers) worker thread(s) beside the audio thread")
            openShow()
            do { try publishLayout(fadeFrames: 0) } catch { log("error: \(error); playing silence until the show or settings are fixed") }
            rebuildMonitor()
            applyListen()
            applyTestSignal()
            io = AudioEngineIO(core: core, config: config, queue: queue, log: log)
            io.start()
            startControl()
            startOSC()
            startMIDI()
            every(0.05) { [self] in core.collect() }
            every(0.1) { [self] in flushJournal() }
            every(0.05) { [self] in sendMeters(); sendSpectrum() }
            every(0.1) { [self] in sendActivity() }
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
            rebuildMonitor()
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
        rebuildMonitor()
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
        var statusChanged = applyListen()
        if case .removeSource(let id) = command, owners.removeValue(forKey: id) != nil { statusChanged = true }
        if statusChanged { broadcastStatus() }
        echo(command)
    }

    // MARK: - The monitor

    /// Builds the binaural monitor from engine.json's `monitor` and the show's speakers and
    /// listener, when either changed.
    private func rebuildMonitor() {
        let key = MonitorKey(settings: config.monitor, speakers: scene.system.speakers, listener: scene.system.listener,
                             sampleRate: config.sampleRate, air: config.airTemperatureC, outputs: config.outputs)
        guard key != monitorKey else { return }
        let first = monitorKey == nil
        monitorKey = key
        guard let m = config.monitor, m.isOn else {
            core.setMonitor(left: nil, right: nil, gain: 0, speakers: [])
            if !first && monitorInfo != "off" { log("monitor: off") }
            monitorInfo = "off"
            return
        }
        guard config.hasMonitorOutputs else {
            core.setMonitor(left: nil, right: nil, gain: 0, speakers: [])
            monitorInfo = "off: Feral has \(config.outputs) outputs, which leaves no room for Binaural L and R (at most \(Routing.maxChannels - 2))"
            log("monitor: \(monitorInfo)")
            return
        }
        var notes: [String] = []
        // Binaural L and R are the two outputs after Feral's own.
        let left = m.left.map { _ in config.outputs }
        let right = m.right.map { _ in config.outputs + 1 }
        let hrirs: HRIRSet
        do { hrirs = try hrirSet(m.hrtf) } catch {
            notes.append("\(error); using the spherical head model")
            hrirs = SphericalHead(sampleRate: config.sampleRate)
        }
        let speakers = scene.monitorSpeakers(hrirs: hrirs, sampleRate: config.sampleRate,
                                             speedOfSound: feral_speed_of_sound(config.airTemperatureC))
        core.setMonitor(left: left, right: right, gain: Float(pow(10, m.gainDB / 20)), speakers: speakers)
        let outs = [m.left, m.right].map { $0.map { "\($0)" } ?? "-" }.joined(separator: "/")
        monitorInfo = "card outputs \(outs), \(hrirs.name), \(speakers.count) speaker(s)" + (notes.isEmpty ? "" : "; " + notes.joined(separator: "; "))
        log("monitor: binaural on \(monitorInfo)")
    }

    /// The HRIRs for engine.json's `hrtf` (a folder; none for the head model), kept while unchanged.
    private func hrirSet(_ path: String?) throws -> HRIRSet {
        if path == MonitorSettings.headModel { return SphericalHead(sampleRate: config.sampleRate) }
        guard let path, !path.isEmpty else {
            // The default: the HRTF folder next to engine.json, when it is there.
            let folder = options.configURL.deletingLastPathComponent().appendingPathComponent("HRTF")
            guard FileManager.default.fileExists(atPath: folder.path) else { return SphericalHead(sampleRate: config.sampleRate) }
            do { return try hrirSet(folder.path) } catch {
                log("monitor: \(error); using the spherical head model")
                return SphericalHead(sampleRate: config.sampleRate)
            }
        }
        let expanded = NSString(string: path).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
            : options.configURL.deletingLastPathComponent().appendingPathComponent(expanded)
        if let c = hrirCache, c.path == url.path, c.rate == config.sampleRate { return c.set }
        let set = try HRIRFolder(folder: url, sampleRate: config.sampleRate)
        hrirCache = (url.path, config.sampleRate, set)
        return set
    }

    /// Writes `monitor` into engine.json and plays it at once (a change of card outputs reopens
    /// the audio, a short gap, as any patch change does).
    private func setMonitor(_ m: MonitorSettings?, origin: String) throws {
        var trial = config
        trial.monitor = m
        try trial.validate()
        if let m, m.hrtf != nil { _ = try hrirSet(m.hrtf) }
        var json = try readConfigJSON()
        if let m {
            json["monitor"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(m))
        } else {
            json.removeValue(forKey: "monitor")
        }
        try writeConfig(json)
        log("\(origin): monitor \(m?.isOn == true ? "set" : "off")")
        if trial.sameDeviceSettings(as: config) {
            config.monitor = m
            rebuildMonitor()
            broadcastStatus()
        } else {
            reload()
            server?.broadcast(.patch(patch: patchInfo))
            queue.asyncAfter(deadline: .now() + 0.5) { [self] in broadcastStatus() }
        }
    }

    /// Hands the core what the monitor hears, by input. Returns true when the solo or PFL lost a
    /// source that is gone.
    @discardableResult
    private func applyListen() -> Bool {
        let alive = Set(scene.show.sources.map(\.id))
        let before = (listenSolo, listenPFL)
        listenSolo = listenSolo.filter { alive.contains($0) }
        listenPFL = listenPFL.filter { alive.contains($0) }
        let n = Routing.maxChannels
        var solo = [Bool](repeating: false, count: n)
        var pfl = [(Float, Float)](repeating: (0, 0), count: n)
        for id in listenSolo {
            if let s = scene.source(id), (1...n).contains(s.input) { solo[s.input - 1] = true }
        }
        for id in listenPFL {
            guard let s = scene.source(id), (1...n).contains(s.input) else { continue }
            // A stereo pair's sides go left and right; a mono source to both at -3 dB.
            var side: (Float, Float) = (0.7071, 0.7071)
            if let g = scene.show.sourceGroups.first(where: { $0.stereo && $0.sources.prefix(2).contains(id) }), g.sources.count >= 2 {
                side = g.sources[0] == id ? (1, 0) : (0, 1)
            }
            let i = s.input - 1
            pfl[i] = (min(1, pfl[i].0 + side.0), min(1, pfl[i].1 + side.1))
        }
        for i in 0..<n { core.setListen(input: i, solo: solo[i], pflLeft: pfl[i].0, pflRight: pfl[i].1) }
        return before.0 != listenSolo || before.1 != listenPFL
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
        // Sources OSC or tracking owns keep their position; the recall sets the rest of their values.
        let live = Set(owners.keys)
        let kept = snapshot.sources.filter { live.contains($0.id) && $0.values.position != nil }.count
        if kept > 0 { log("snapshot \(snapshot.label): \(kept) source(s) keep their live position (OSC or tracking owns them)") }
        let fade = SnapshotFade(snapshot: snapshot.withoutPositions(of: live), state: scene, seconds: seconds,
                                curve: curve)
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
        if cue.reclaim, let id = cue.snapshot, let snapshot = scene.snapshot(id) {
            release(snapshot.sources.map(\.id), origin: "cue \(cue.label)")
        }
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
            watchers[id] = nil
            if analysers.removeValue(forKey: id) != nil { pickAnalysis(newest: nil) }
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
                takeOver(command.touchedSources)
                try apply(command, origin: origin)
                // A move from the app or feral-cli hands the source back to cues: the newest owner wins.
                if case .updateSources(let updates) = command {
                    release(updates.filter { $0.values.position != nil }.map(\.id), origin: origin)
                }
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
            case .release(let sources):
                release(sources, origin: origin)
                broadcastStatus()
            case .watch(let meters, let activity):
                watchers[client] = meters || activity ? Watch(meters: meters, activity: activity) : nil
            case .listDevices:
                server?.send(.devices(list: deviceList(), selected: config.device), to: client)
            case .setDevice(let device):
                try setDevice(device, origin: origin)
            case .getPatch:
                server?.send(.patch(patch: patchInfo), to: client)
            case .setPatch(let inputs, let outputs, let monitor):
                try setPatch(inputs: inputs, outputs: outputs, monitor: monitor, origin: origin)
            case .setChannelCounts(let inputs, let outputs):
                try setChannelCounts(inputs: inputs, outputs: outputs, origin: origin)
            case .analyse(let input):
                analysers[client] = input.flatMap { $0 >= 1 && $0 <= config.inputs ? $0 : nil }
                pickAnalysis(newest: analysers[client])
            case .setMonitor(let monitor):
                try setMonitor(monitor, origin: origin)
            case .listen(let solo, let pfl):
                listenSolo = solo
                listenPFL = pfl
                applyListen()
                broadcastStatus()
            }
        } catch {
            server?.send(.error(message: "\(error)"), to: client)
        }
    }

    // MARK: - The audio device

    private func deviceList() -> [AudioDeviceSummary] {
        ((try? AudioDevices.all()) ?? []).map {
            AudioDeviceSummary(uid: $0.uid, name: $0.name, transport: $0.transport, inputChannels: $0.inputChannels,
                               outputChannels: $0.outputChannels, sampleRate: $0.sampleRate,
                               sampleRates: $0.availableSampleRates, isAggregate: $0.isAggregate)
        }
    }

    /// Writes `device` into engine.json (keeping everything else in it) and reopens the audio on it.
    private func setDevice(_ device: String, origin: String) throws {
        let list = deviceList()
        guard let chosen = list.first(where: { $0.uid == device }) ?? list.first(where: { $0.matches(device) }) else {
            throw ConfigError("no audio device \(device) on this Mac")
        }
        if chosen.isAggregate && config.refuseAggregateDevices {
            throw ConfigError("\(chosen.name) is an aggregate device; aggregates drift or resample between clocks, so the engine refuses them")
        }
        var json = try readConfigJSON()
        json["device"] = chosen.uid
        try writeConfig(json)
        log("\(origin): audio device set to \(chosen.name) (\(chosen.uid)) in \(options.configURL.path)")
        reload()
        server?.broadcast(.devices(list: list, selected: config.device))
        // The device opens in the background; tell clients how it went.
        for delay in [0.5, 2.0] {
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                broadcastStatus()
                server?.broadcast(.patch(patch: patchInfo))
            }
        }
    }

    /// engine.json as a JSON object, to change a few keys and keep the rest as written.
    private func readConfigJSON() throws -> [String: Any] {
        let url = options.configURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw ConfigError("\(url.path) is not a JSON object")
        }
        return object
    }

    private func writeConfig(_ json: [String: Any]) throws {
        let url = options.configURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    private var patchInfo: PatchInfo {
        let dev = io.openDevice
        return PatchInfo(inputs: config.inputChannels, outputs: config.outputChannels, device: dev?.name,
                         deviceInputs: dev?.inputChannels ?? 0, deviceOutputs: dev?.outputChannels ?? 0,
                         customInputs: config.inputPatch != nil, customOutputs: config.outputPatch != nil,
                         monitor: config.hasMonitorOutputs ? config.monitor?.channels ?? [0, 0] : nil)
    }

    /// Writes Feral's input and output counts into engine.json and reopens the audio with them.
    private func setChannelCounts(inputs: Int?, outputs: Int?, origin: String) throws {
        var trial = config
        if let inputs {
            let used = scene.show.sources.map(\.input).max() ?? 0
            guard inputs >= used else { throw ConfigError("source on input \(used) needs at least \(used) inputs; move or delete it first") }
            trial.inputs = inputs
        }
        if let outputs {
            let used = scene.system.speakers.map(\.output).max() ?? 0
            guard outputs >= used else { throw ConfigError("speaker on output \(used) needs at least \(used) outputs; move or delete it first") }
            trial.outputs = outputs
        }
        try trial.validate()
        var json = try readConfigJSON()
        if inputs != nil { json["inputs"] = trial.inputs }
        if outputs != nil { json["outputs"] = trial.outputs }
        try writeConfig(json)
        log("\(origin): Feral now has \(trial.inputs) inputs and \(trial.outputs) outputs")
        reload()
        server?.broadcast(.patch(patch: patchInfo))
        for delay in [0.5, 2.0] {
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                broadcastStatus()
                server?.broadcast(.patch(patch: patchInfo))
            }
        }
    }

    /// Writes inputPatch and outputPatch into engine.json and reopens the audio on them.
    private func setPatch(inputs: [Int]?, outputs: [Int]?, monitor: [Int]?, origin: String) throws {
        var trial = config
        if let inputs { trial.inputPatch = Array(inputs.prefix(config.inputs)) }
        if let outputs { trial.outputPatch = Array(outputs.prefix(config.outputs)) }
        if let monitor {
            var m = trial.monitor ?? MonitorSettings()
            let c = monitor + [0, 0]
            m.left = c[0] > 0 ? c[0] : nil
            m.right = c[1] > 0 ? c[1] : nil
            trial.monitor = m
        }
        try trial.validate()
        var json = try readConfigJSON()
        if let p = trial.inputPatch, inputs != nil { json["inputPatch"] = p }
        if let p = trial.outputPatch, outputs != nil { json["outputPatch"] = p }
        if monitor != nil, let m = trial.monitor { json["monitor"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) }
        try writeConfig(json)
        func count(_ p: [Int]?) -> Int { p?.filter { $0 > 0 }.count ?? 0 }
        log("\(origin): patch set (\(count(trial.inputPatch)) inputs, \(count(trial.outputPatch)) outputs patched)")
        reload()
        server?.broadcast(.patch(patch: patchInfo))
        for delay in [0.5, 2.0] {
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                broadcastStatus()
                server?.broadcast(.patch(patch: patchInfo))
            }
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
                            nextCue: scene.cue(after: currentCue)?.id, fading: fades.flatMap { $0.fade.sources }, audio: audio,
                            owners: owners, osc: oscState, midi: midiState, oscPort: osc?.port, solo: listenSolo, pfl: listenPFL,
                            monitor: config.monitor, monitorInfo: monitorInfo)
    }

    private func broadcastStatus() {
        let s = status
        server?.broadcast(.status(status: s))
        let cues = ControlMapper(state: scene).cueMessages(s)
        for (peer, adm) in subscribers where !adm { osc?.send(cues, to: peer) }
    }

    /// Stops any fade on sources something is setting directly.
    private func takeOver(_ sources: [UUID]) {
        guard !sources.isEmpty else { return }
        let touched = Set(sources)
        for i in fades.indices { fades[i].fade.remove(touched) }
    }

    /// Hands sources' positions back to cues.
    private func release(_ sources: [UUID], origin: String) {
        let freed = sources.filter { owners.removeValue(forKey: $0) != nil }
        guard !freed.isEmpty else { return }
        log("\(origin): \(freed.count) source(s) handed back to cues")
        broadcastStatus()
    }

    // MARK: - OSC and MIDI

    private func startOSC() {
        guard config.oscPort != 0 else { log("osc: off (oscPort is 0)"); return }
        let server = OSCServer(queue: queue)
        server.onLog = { log($0) }
        server.onReady = { [weak self] port in
            self?.oscState = "UDP port \(port) on \(self?.config.oscAddress ?? "")"
            self?.broadcastStatus()
        }
        server.onMessage = { [weak self] m, peer in self?.handle(m, from: peer) }
        server.onBadPacket = { [weak self] why, peer in self?.logOnce("bad:\(peer.host)", "osc: unreadable packet from \(peer): \(why)") }
        do {
            try server.start(address: config.oscAddress, port: config.oscPort)
            oscState = "starting on UDP port \(config.oscPort)"
        } catch {
            oscState = "not listening: \(error)"
            log("error: OSC cannot listen on \(config.oscAddress) UDP port \(config.oscPort): \(error)")
        }
        osc = server
    }

    private func startMIDI() {
        guard config.midi else { log("midi: off (midi is false)"); return }
        let input = MIDIInput(queue: queue, only: config.midiInputs)
        input.onLog = { [weak self] line in
            log(line)
            if line.hasPrefix("midi: listening to ") { self?.midiState = String(line.dropFirst("midi: listening to ".count)); self?.broadcastStatus() }
        }
        input.onMessage = { [weak self] m, source in self?.handle(m, from: source) }
        input.start()
        midiInput = input
    }

    /// An OSC message: the trigger map first, then Feral's and ADM-OSC's namespaces.
    private func handle(_ m: OSCMessage, from peer: OSCServer.Peer) {
        let mapper = ControlMapper(state: scene)
        let triggered = mapper.triggered(by: m)
        if !triggered.isEmpty { log("osc: \(m.description) from \(peer) matches the trigger map") }
        var problems = run(triggered, origin: "OSC trigger", peer: peer)
        var did = triggered.isEmpty ? [] : ["trigger: " + summary(triggered)]
        let root = m.parts.first
        guard root == "feral" || root == "adm" else {
            if triggered.isEmpty {
                logOnce(m.address, "osc: nothing listens for \(m.address) (from \(peer)); add a trigger for it")
                noteHeard(.osc, from: "\(peer)", m.description, ["nothing listens for \(m.address); add a trigger for it"], handled: false)
            } else {
                noteHeard(.osc, from: "\(peer)", m.description, did + problems, handled: problems.isEmpty)
            }
            return
        }
        do {
            let actions = try mapper.actions(for: m)
            did.append(summary(actions))
            problems += run(actions, origin: root == "adm" ? "ADM-OSC" : "OSC", peer: peer)
        } catch {
            logOnce("err:\(m.address)", "osc: \(error) (from \(peer))")
            problems.append("\(error)")
        }
        noteHeard(.osc, from: "\(peer)", m.description, did + problems, handled: problems.isEmpty)
    }

    private func handle(_ m: MIDIMessage, from source: String) {
        let actions = ControlMapper(state: scene).triggered(by: m)
        guard !actions.isEmpty else {
            logOnce("midi:\(m)", "midi: \(m) from \(source); no trigger for it")
            noteHeard(.midi, from: source, m.description, ["no trigger for it; add one to the trigger map"], handled: false)
            return
        }
        log("midi: \(m) from \(source)")
        let problems = run(actions, origin: "MIDI", peer: nil)
        noteHeard(.midi, from: source, m.description, ["trigger: " + summary(actions)] + problems, handled: problems.isEmpty)
    }

    /// Notes a message for the control monitor, if a client is watching.
    private func noteHeard(_ kind: ControlActivity.Kind, from: String, _ message: String, _ result: [String], handled: Bool) {
        guard watchers.values.contains(where: { $0.activity }) else { return }
        guard heard.count < Engine.maxHeard else { heardDropped += 1; return }
        heard.append(ControlActivity(time: Date().timeIntervalSince1970, kind: kind, from: from, message: message,
                                     result: result.joined(separator: "; "), handled: handled))
    }

    private func sendActivity() {
        guard !heard.isEmpty || heardDropped > 0 else { return }
        let clients = watchers.filter { $0.value.activity }.map(\.key)
        server?.send(.activity(lines: heard, dropped: heardDropped), to: clients)
        heard = []
        heardDropped = 0
    }

    /// Points the core's analysis tap at the newest request, or at any still wanted, or off.
    private func pickAnalysis(newest: Int?) {
        let input = newest ?? (analysed.flatMap { a in analysers.values.contains(a) ? a : nil }) ?? analysers.values.first
        guard input != analysed else { return }
        analysed = input
        core.setAnalysisInput(input.map { $0 - 1 })
    }

    private func sendSpectrum() {
        guard let input = analysed else { return }
        let clients = analysers.filter { $0.value == input }.map(\.key)
        guard !clients.isEmpty else { return }
        let a = core.readAnalysis(frames: Spectrum.fftSize)
        guard a.written > 0 else { return }
        let frame = SpectrumFrame(input: input, pre: Spectrum.analyse(a.pre, sampleRate: config.sampleRate).map { ($0 * 10).rounded() / 10 },
                                  post: Spectrum.analyse(a.post, sampleRate: config.sampleRate).map { ($0 * 10).rounded() / 10 })
        server?.send(.spectrum(frame: frame), to: clients)
    }

    private func sendMeters() {
        let clients = watchers.filter { $0.value.meters }.map(\.key)
        guard !clients.isEmpty else { return }
        let l = core.readMeters(inputs: config.inputs, outputs: config.outputs)
        let frame = MeterFrame(inputPeak: l.inputPeak.map(MeterFrame.dB), inputRMS: l.inputRMS.map(MeterFrame.dB),
                               outputPeak: l.outputPeak.map(MeterFrame.dB), outputRMS: l.outputRMS.map(MeterFrame.dB),
                               firstInputChannel: config.firstInputChannel, firstOutputChannel: config.firstOutputChannel,
                               load: core.stats().maxLoad,
                               inputReduction: core.readReduction(inputs: config.inputs).map { ($0 * 10).rounded() / 10 },
                               inputBandReduction: core.readBandReduction(inputs: config.inputs).map { $0.map { ($0 * 10).rounded() / 10 } })
        server?.send(.meters(frame: frame), to: clients)
    }

    /// What OSC's or MIDI's actions do, for the control monitor.
    private func summary(_ actions: [ControlAction]) -> String {
        func sources(_ ids: [UUID]) -> String {
            let names = ids.compactMap { scene.source($0)?.label }
            return names.count == 1 ? "source \(names[0])" : "\(ids.count) sources"
        }
        return actions.map { a -> String in
            switch a {
            case .go(let cue): return cue.map { "GO cue \($0)" } ?? "GO"
            case .recall(let s, let f): return "recall snapshot \(s)" + (f.map { " over \($0) s" } ?? "")
            case .stopFades: return "stop fades"
            case .save: return "save"
            case .apply(let c): return describe(c)
            case .update(let u, let owner):
                return "set \(sources(u.map(\.id)))" + (owner.map { "; \($0.label) owns its position" } ?? "")
            case .release(let ids): return "hand \(sources(ids)) back to cues"
            case .subscribe(let port, let adm): return "subscribed" + (port.map { " (to port \($0))" } ?? "") + (adm ? ", ADM-OSC" : "")
            case .unsubscribe: return "unsubscribed"
            case .reply(let r): return "answered \(r.description)"
            }
        }.joined(separator: "; ")
    }

    /// Runs OSC's and MIDI's actions as the app's requests run. Returns what went wrong.
    @discardableResult
    private func run(_ actions: [ControlAction], origin: String, peer: OSCServer.Peer?) -> [String] {
        var problems: [String] = []
        for action in actions {
            do {
                switch action {
                case .go(let cue):
                    try go(cue, origin: origin)
                case .recall(let which, let seconds):
                    guard let snapshot = scene.snapshot(matching: which) else { throw ConfigError("no snapshot \(which)") }
                    log("snapshot \(snapshot.label) recalled (\(origin)) over \(seconds ?? snapshot.fadeSeconds) s")
                    recall(snapshot, seconds: seconds, curve: nil, followCue: nil)
                case .stopFades:
                    log("\(origin): stop fades")
                    stopFades()
                case .save:
                    try save()
                case .apply(let command):
                    takeOver(command.touchedSources)
                    try apply(command, origin: origin)
                    log("\(origin): \(describe(command))")
                case .update(let updates, let owner):
                    takeOver(updates.map(\.id))
                    try apply(.updateSources(updates: updates), origin: origin)
                    if let owner {
                        var changed = false
                        for u in updates where u.values.position != nil && owners[u.id] != owner {
                            owners[u.id] = owner
                            changed = true
                        }
                        if changed { broadcastStatus() }
                    }
                case .release(let sources):
                    release(sources, origin: origin)
                case .subscribe(let port, let adm):
                    guard let peer else { break }
                    let target = OSCServer.Peer(host: peer.host, port: port ?? peer.port)
                    if subscribers.count >= 32 && subscribers[target] == nil { throw ConfigError("32 OSC subscribers already") }
                    if subscribers.updateValue(adm, forKey: target) == nil {
                        log("osc: \(target) subscribed" + (adm ? " (ADM-OSC)" : ""))
                    }
                    osc?.send(ControlMapper(state: scene).dump(adm: adm, status: status), to: target)
                case .unsubscribe(let port):
                    guard let peer else { break }
                    let target = OSCServer.Peer(host: peer.host, port: port ?? peer.port)
                    if subscribers.removeValue(forKey: target) != nil {
                        log("osc: \(target) unsubscribed")
                        osc?.forget(target)
                    }
                case .reply(let message):
                    if let peer { osc?.send([message], to: peer) }
                }
            } catch {
                logOnce("run:\(error)", "\(origin): \(error)")
                problems.append("\(error)")
                if let peer { osc?.send([OSCMessage("/feral/error", [.string("\(error)")])], to: peer) }
            }
        }
        return problems
    }

    /// Sends OSC subscribers what a command changed.
    private func echo(_ command: Command) {
        guard !subscribers.isEmpty else { return }
        let mapper = ControlMapper(state: scene)
        var feral: [OSCMessage]?, adm: [OSCMessage]?
        for (peer, wantsADM) in subscribers {
            if wantsADM {
                if adm == nil { adm = mapper.echo(command, adm: true) }
                osc?.send(adm!, to: peer)
            } else {
                if feral == nil { feral = mapper.echo(command, adm: false) }
                osc?.send(feral!, to: peer)
            }
        }
    }

    private func logOnce(_ key: String, _ line: String) {
        let now = Date()
        if let last = lastLogged[key], now.timeIntervalSince(last) < 10 { return }
        if lastLogged.count > 500 { lastLogged = lastLogged.filter { now.timeIntervalSince($0.value) < 10 } }
        lastLogged[key] = now
        log(line)
    }

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
        case .setSourceGroup(let g): return "set source group \(g.label)"
        case .setListener(let l): return String(format: "moved the listener to %.1f %.1f %.1f, facing %.0f°", l.position.x, l.position.y, l.position.z, l.facing)
        case .removeSourceGroup: return "removed a source group"
        case .captureSnapshot(let c): return "stored snapshot \(c.number) \(c.name)"
        case .setSnapshot(let s): return "set snapshot \(s.label)"
        case .removeSnapshot: return "removed a snapshot"
        case .setCue(let c): return "set cue \(c.label)"
        case .removeCue: return "removed a cue"
        case .renameShow(let n): return "renamed the show \(n)"
        case .setControl(let c): return "set the trigger map (\(c.triggers.count) trigger(s)) and ADM-OSC box"
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
        // Rebuild the monitor even if nothing it uses changed (a new HRTF folder, say).
        monitorKey = nil
        hrirCache = nil
        if !old.sameDeviceSettings(as: newConfig) {
            if newConfig.sampleRate != old.sampleRate {
                log("reload: sampleRate changed; load figures use the old rate until the engine restarts")
            }
            io.reconfigure(newConfig)
        }
        if old.controlAddress != newConfig.controlAddress || old.controlPort != newConfig.controlPort {
            log("reload: the control link keeps \(old.controlAddress) port \(old.controlPort) until the engine restarts")
        }
        if old.oscAddress != newConfig.oscAddress || old.oscPort != newConfig.oscPort || old.midi != newConfig.midi
            || old.midiInputs != newConfig.midiInputs {
            log("reload: OSC and MIDI keep their settings until the engine restarts")
        }
        if ShowFile.url(for: newConfig, configURL: options.configURL) != showURL {
            flushJournal()
            housekeeping.sync {}
            stopFades()
            owners = [:]
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
        osc?.stop()
        midiInput?.stop()
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

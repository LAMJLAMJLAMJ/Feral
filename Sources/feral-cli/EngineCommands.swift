#if canImport(Network)
import FeralControl
import FeralScene
import Foundation

/// A short session with the running engine: connect, get the show, send one request, print the reply.
final class EngineSession {
    private let queue = DispatchQueue(label: "feral-cli.control")
    private let client: ControlClient
    private let signal = DispatchSemaphore(value: 0)
    private var mirror = MirroredShow()
    private var events: [Event] = []

    init(host: String, port: Int) {
        client = ControlClient(host: host, port: port, name: "feral-cli", queue: queue)
        client.onEvent = { [unowned self] event in
            self.mirror.handle(event)
            self.events.append(event)
            self.signal.signal()
        }
    }

    /// Connects and waits for the show.
    func connect() -> ShowState {
        client.start()
        let deadline = Date() + 3
        while Date() < deadline {
            if let state = queue.sync(execute: { mirror.state }) { return state }
            _ = signal.wait(timeout: .now() + 0.1)
        }
        fail("no engine answered at \(client.host) port \(client.port). Is it running? (./scripts/engine.sh status)")
    }

    var state: ShowState { queue.sync { mirror.state! } }
    var status: EngineStatus? { queue.sync { mirror.status } }

    /// Sends a request and waits up to `seconds` for an error (for requests the engine does not answer).
    func send(_ request: Request, waiting seconds: Double) {
        queue.sync { events = [] }
        client.send(request)
        let deadline = Date() + seconds
        while Date() < deadline {
            let error: String? = queue.sync {
                for e in events { if case .error(let m) = e { return m } }
                return nil
            }
            if let error { fail(error) }
            _ = signal.wait(timeout: .now() + 0.05)
        }
    }

    /// Sends a request and waits for the first event `done` accepts, or an error.
    @discardableResult
    func send(_ request: Request, timeout: Double = 3, until done: @escaping (Event) -> Bool) -> Event {
        queue.sync { events = [] }
        client.send(request)
        let deadline = Date() + timeout
        while Date() < deadline {
            let found: Event? = queue.sync {
                events.first { e in
                    if case .error = e { return true }
                    return done(e)
                }
            }
            if let found {
                if case .error(let message) = found { fail(message) }
                return found
            }
            _ = signal.wait(timeout: .now() + 0.1)
        }
        fail("the engine did not answer in \(Int(timeout)) s")
    }

    /// Hands every event that arrives to `each` for `seconds` (nil: until Ctrl-C).
    func stream(for seconds: Double?, _ each: (Event) -> Void) {
        let until = seconds.map { Date() + $0 }
        while until.map({ Date() < $0 }) ?? true {
            _ = signal.wait(timeout: .now() + 0.1)
            let arrived: [Event] = queue.sync { defer { events = [] }; return events }
            for e in arrived { each(e) }
        }
    }

    func close() { client.stop() }
}

func isStatus(_ e: Event) -> Bool {
    if case .status = e { return true }
    return false
}

func printStatus(_ s: EngineStatus?, _ state: ShowState) {
    guard let s else { return }
    let current = s.currentCue.flatMap { state.cue($0) }.map(\.label) ?? "none"
    let next = s.nextCue.flatMap { state.cue($0) }.map(\.label) ?? "none"
    print("show:   \(state.show.name)  (\(s.showPath))")
    print("        \(state.show.sources.count) source(s), \(state.system.speakers.count) speaker(s), "
          + "\(state.show.snapshots.count) snapshot(s), \(state.show.cues.count) cue(s); "
          + (s.unsaved == 0 ? "saved" : "\(s.unsaved) unsaved change(s), kept in the journal"))
    print("cue:    current \(current), next \(next)" + (s.fading.isEmpty ? "" : "; fading \(s.fading.count) source(s)"))
    print("audio:  \(s.audio)")
    print("osc:    \(s.osc.isEmpty ? "off" : s.osc)")
    print("midi:   \(s.midi.isEmpty ? "off" : s.midi)")
    for (id, owner) in s.owners.sorted(by: { (state.source($0.key)?.number ?? 0) < (state.source($1.key)?.number ?? 0) }) {
        print("live:   source \(state.source(id)?.label ?? id.uuidString) position from \(owner.label)")
    }
    print("engine: feral-engine \(s.version)")
}

/// The engine's port: --port, else engine.json's controlPort, else 9100.
func enginePort() -> Int {
    if let port { return port }
    return (try? EngineConfig.load(from: configURL))?.controlPort ?? defaultControlPort
}

func runEngineCommand(_ command: String, _ args: [String]) {
    let session = EngineSession(host: host, port: enginePort())
    let state = session.connect()
    defer { session.close() }

    func applied(_ c: Command) -> (Event) -> Bool {
        { e in
            if case .applied(_, let origin, let command) = e { return origin == "feral-cli" && command == c }
            return false
        }
    }

    switch command {
    case "status":
        printStatus(session.status, state)

    case "go":
        guard args.count <= 1 else { fail("go takes at most one cue number") }
        if args.isEmpty && state.show.cues.isEmpty { fail("the show has no cues; add one with feral-cli cue 1 SNAPSHOT") }
        session.send(.go(cue: args.first), until: isStatus)
        printStatus(session.status, session.state)

    case "recall":
        guard args.count == 1 else { fail("recall needs a snapshot number or name") }
        guard let snap = state.snapshot(matching: args[0]) else { fail("no snapshot \(args[0])") }
        session.send(.recall(snapshot: snap.id.uuidString, fadeSeconds: fade), until: isStatus)
        print("recalled snapshot \(snap.label) over \(fade ?? snap.fadeSeconds) s")

    case "move":
        guard (3...4).contains(args.count), let x = Double(args[1]), let y = Double(args[2]) else {
            fail("move needs a source number and X Y (and Z) in metres: feral-cli move 1 0 6 1.6")
        }
        guard let src = state.source(matching: args[0]) else { fail("no source \(args[0])") }
        let z = args.count == 4 ? Double(args[3]) : src.position.z
        guard let z else { fail("Z must be a number") }
        let c = Command.updateSources(updates: [SourceUpdate(id: src.id, values: SourceValues(position: Position(x, y, z)))])
        session.send(.apply(command: c), until: applied(c))
        print("moved source \(src.label) to [\(x), \(y), \(z)]")

    case "store":
        guard args.count == 1 else { fail("store needs a name in quotes: feral-cli store \"Act 1\"") }
        let capture = SnapshotCapture(number: state.nextSnapshotNumber, name: args[0], fadeSeconds: fade ?? 0)
        let c = Command.captureSnapshot(capture: capture)
        session.send(.apply(command: c), until: applied(c))
        print("stored snapshot \(capture.number) \(capture.name) (\(state.show.sources.count) source(s))")

    case "cue":
        guard args.count == 2 else { fail("cue needs a number and a snapshot: feral-cli cue 1 2 --fade 5") }
        guard Double(args[0]) != nil else { fail("a cue number is a number such as 12 or 12.5") }
        guard let snap = state.snapshot(matching: args[1]) else { fail("no snapshot \(args[1])") }
        let existing = state.cue(matching: args[0])
        let cue = Cue(id: existing?.id ?? UUID(), number: args[0], name: cueName ?? existing?.name ?? snap.name,
                      snapshot: snap.id, fadeSeconds: fade ?? existing?.fadeSeconds, curve: existing?.curve,
                      autoFollow: follow)
        let c = Command.setCue(cue: cue)
        session.send(.apply(command: c), until: applied(c))
        print("\(existing == nil ? "added" : "changed") cue \(cue.label): snapshot \(snap.label)"
              + (cue.fadeSeconds.map { " over \($0) s" } ?? "") + (follow ? ", auto-follow" : ""))

    case "stop":
        session.send(.stopFades, until: isStatus)
        print("stopped every fade")

    case "save":
        session.send(.save, until: isStatus)
        print("saved \(session.status?.showPath ?? "the show")")

    case "trigger":
        var control = state.show.control
        switch args.first ?? "list" {
        case "list":
            printTriggers(control)
            return
        case "add":
            let t = parseTrigger(Array(args.dropFirst()))
            control.triggers.append(t)
            print("added trigger \(control.triggers.count): \(t.on) -> \(t.action)")
        case "remove":
            guard args.count == 2, let n = Int(args[1]), n >= 1, n <= control.triggers.count else {
                fail("trigger remove needs a number from feral-cli trigger list")
            }
            let t = control.triggers.remove(at: n - 1)
            print("removed trigger \(n): \(t.on) -> \(t.action)")
        case let other:
            fail("trigger \(other)? Try trigger list, trigger add or trigger remove")
        }
        let c = Command.setControl(control: control)
        session.send(.apply(command: c), until: applied(c))

    case "admbox":
        if args.isEmpty { printBox(state.show.control.admBox); return }
        let v = args.compactMap(Double.init)
        guard args.count == 6, v.count == 6 else { fail("admbox needs min x y z and max x y z in metres: feral-cli admbox -10 -2 0 10 20 10") }
        var control = state.show.control
        control.admBox = ADMBox(min: Position(v[0], v[1], v[2]), max: Position(v[3], v[4], v[5]))
        let c = Command.setControl(control: control)
        session.send(.apply(command: c), until: applied(c))
        printBox(control.admBox)

    case "release":
        guard !args.isEmpty else { fail("release needs source numbers: feral-cli release 1 2") }
        let ids = args.map { a -> UUID in
            guard let s = state.source(matching: a) else { fail("no source \(a)") }
            return s.id
        }
        session.send(.release(sources: ids), until: isStatus)
        print("handed \(ids.count) source(s) back to cues")

    case "meters":
        // The highest peak and RMS seen per channel over --seconds (default 2).
        session.send(.watch(meters: true, activity: false), until: { e in
            if case .meters = e { return true }
            return false
        })
        var frame: MeterFrame?
        session.stream(for: seconds ?? 2) { e in
            guard case .meters(let f) = e else { return }
            guard var m = frame, m.inputPeak.count == f.inputPeak.count, m.outputPeak.count == f.outputPeak.count else {
                frame = f
                return
            }
            m.inputPeak = zip(m.inputPeak, f.inputPeak).map { max($0, $1) }
            m.inputRMS = zip(m.inputRMS, f.inputRMS).map { max($0, $1) }
            m.outputPeak = zip(m.outputPeak, f.outputPeak).map { max($0, $1) }
            m.outputRMS = zip(m.outputRMS, f.outputRMS).map { max($0, $1) }
            m.load = max(m.load, f.load)
            frame = m
        }
        guard let frame else { fail("the engine sent no meters") }
        printMeters(frame, state, all: args.contains("all"))

    case "device":
        // The audio devices on the engine's Mac, or switch the engine to one.
        let isDevices: (Event) -> Bool = { e in
            if case .devices = e { return true }
            return false
        }
        let request: Request = args.isEmpty ? .listDevices : .setDevice(device: args.joined(separator: " "))
        guard case .devices(let list, let selected) = session.send(request, timeout: 5, until: isDevices) else { return }
        if !args.isEmpty { print("the engine now uses \(list.first { $0.matches(selected) }?.name ?? selected ?? "?")") }
        for d in list {
            let mark = d.matches(selected) ? "*" : " "
            print("\(mark) \(pad(d.name, 34)) in \(pad(String(d.inputChannels), 4)) out \(pad(String(d.outputChannels), 4)) "
                  + "\(Int(d.sampleRate)) Hz  \(d.transport)" + (d.isAggregate ? "  (aggregate: refused)" : ""))
        }
        if args.isEmpty { print("\n* is the one in engine.json. Switch with: feral-cli device \"NAME\"") }

    case "patch":
        // The patch between the sound card and the engine, or a change to it.
        let isPatch: (Event) -> Bool = { e in
            if case .patch = e { return true }
            return false
        }
        guard case .patch(let current) = session.send(.getPatch, timeout: 5, until: isPatch) else { return }
        var patch = current
        if !args.isEmpty {
            // patch in|out FERAL-CHANNELS DEVICE-CHANNEL|none
            guard args.count == 3, ["in", "out"].contains(args[0]) else {
                fail("usage: feral-cli patch in|out CHANNELS FIRST-DEVICE-CHANNEL (or none), e.g. patch in 1-2 33")
            }
            let isIn = args[0] == "in"
            let count = isIn ? patch.inputs.count : patch.outputs.count
            let range = args[1].split(separator: "-").compactMap { Int($0) }
            guard (1...2).contains(range.count), range[0] >= 1, range.last! <= count, range[0] <= range.last! else {
                fail("'\(args[1])': give Feral \(isIn ? "inputs" : "outputs") as N or N-M, from 1 to \(count)")
            }
            let first: Int
            if args[2] == "none" { first = 0 } else if let n = Int(args[2]), n >= 1 { first = n } else {
                fail("'\(args[2])': give the first sound card channel (from 1), or none")
            }
            var list = isIn ? patch.inputs : patch.outputs
            for (k, ch) in (range[0]...range.last!).enumerated() {
                let device = first == 0 ? 0 : first + k
                if !isIn && device > 0 {
                    // A sound card output takes one Feral output: take it from any other.
                    for j in list.indices where list[j] == device { list[j] = 0 }
                }
                list[ch - 1] = device
            }
            let request: Request = isIn ? .setPatch(inputs: list, outputs: nil) : .setPatch(inputs: nil, outputs: list)
            guard case .patch(let updated) = session.send(request, timeout: 5, until: isPatch) else { return }
            patch = updated
            print("patched\n")
        }
        printPatch(patch, state)

    case "monitor":
        // Every OSC and MIDI message the engine receives, and what it did, as the app's control monitor shows them.
        session.send(.watch(meters: false, activity: true), waiting: 0.3)
        print("watching the engine's OSC and MIDI" + (seconds.map { " for \(Int($0)) s" } ?? "; Ctrl-C to stop"))
        session.stream(for: seconds) { e in
            guard case .activity(let lines, let dropped) = e else { return }
            for l in lines { print(activityLine(l)) }
            if dropped > 0 { print("  (\(dropped) more left out: too many at once)") }
            fflush(stdout)
        }

    default:
        fail("unknown engine command \(command)")
    }
}

/// The patch as two tables, listing patched channels and the ones the show uses.
func printPatch(_ p: PatchInfo, _ state: ShowState) {
    print("sound card: \(p.device ?? "none open")" + (p.device == nil ? "" : " (\(p.deviceInputs) in, \(p.deviceOutputs) out)"))
    var sources: [Int: String] = [:], speakers: [Int: String] = [:]
    for s in state.show.sources { sources[s.input] = sources[s.input].map { $0 + ", " + s.label } ?? s.label }
    for s in state.system.speakers { speakers[s.output] = s.label }
    func table(_ title: String, _ list: [Int], _ names: [Int: String], _ available: Int, _ arrow: String) {
        print("\n\(title)")
        var shown = 0
        for (k, ch) in list.enumerated() where ch > 0 || names[k + 1] != nil {
            let card = ch == 0 ? "-" : (p.device != nil && ch > available ? "\(ch) (card has \(available))" : String(ch))
            print("  \(pad(String(k + 1), 4)) \(pad(names[k + 1] ?? "", 18)) \(arrow) card \(card)")
            shown += 1
        }
        if shown == 0 { print("  nothing patched") }
    }
    table("FERAL INPUT  SOURCE", p.inputs, sources, p.deviceInputs, "<-")
    table("FERAL OUTPUT SPEAKER", p.outputs, speakers, p.deviceOutputs, "->")
    print("\nChange it with, for example: feral-cli patch in 1-2 33   or   feral-cli patch out 5 none")
}

func activityLine(_ l: ControlActivity) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    let time = f.string(from: Date(timeIntervalSince1970: l.time))
    return "\(time)  \(l.kind == .osc ? "OSC " : "MIDI")  \(pad(l.message, 34)) from \(l.from)\n"
        + "              \(l.handled ? "->" : "!!") \(l.result)"
}

/// The meters as a table: every engine input a source uses and every output a speaker uses (or, with
/// `all`, every channel), with the device channel each is on.
func printMeters(_ m: MeterFrame, _ state: ShowState, all: Bool) {
    func level(_ v: Float) -> String { v <= MeterFrame.silence ? "   -inf" : String(format: "%7.1f", v) }
    func bar(_ v: Float) -> String {
        let n = max(0, min(30, Int(((v + 60) / 2).rounded())))
        return String(repeating: "#", count: n) + String(repeating: ".", count: 30 - n)
    }
    let sources = Dictionary(state.show.sources.map { ($0.input, $0.label) }, uniquingKeysWith: { a, b in a + ", " + b })
    let speakers = Dictionary(state.system.speakers.map { ($0.output, $0.label) }, uniquingKeysWith: { a, b in a + ", " + b })
    print("levels in dBFS (peak and RMS), the loudest over the time watched; bar from -60 to 0")
    print("\nINPUTS          device ch   peak     rms")
    for i in m.inputPeak.indices where all || sources[i + 1] != nil || m.inputPeak[i] > MeterFrame.silence {
        print("  \(pad(String(i + 1), 4)) \(pad(sources[i + 1] ?? "", 18)) \(pad(String(m.firstInputChannel + i), 4))"
              + "\(level(m.inputPeak[i])) \(level(m.inputRMS[i]))  \(bar(m.inputRMS[i]))")
    }
    print("\nOUTPUTS         device ch   peak     rms")
    for o in m.outputPeak.indices where all || speakers[o + 1] != nil || m.outputPeak[o] > MeterFrame.silence {
        print("  \(pad(String(o + 1), 4)) \(pad(speakers[o + 1] ?? "", 18)) \(pad(String(m.firstOutputChannel + o), 4))"
              + "\(level(m.outputPeak[o])) \(level(m.outputRMS[o]))  \(bar(m.outputRMS[o]))")
    }
    print(String(format: "\nrender load: %.0f %% of a buffer at most", m.load * 100))
}
#endif

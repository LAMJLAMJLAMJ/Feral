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

    default:
        fail("unknown engine command \(command)")
    }
}
#endif

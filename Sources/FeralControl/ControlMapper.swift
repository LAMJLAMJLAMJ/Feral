import FeralScene
import Foundation

// What OSC and MIDI mean to the show: Feral's own OSC namespace, ADM-OSC, the trigger map and MIDI
// Show Control, turned into actions for the engine. Pure, so every message is tested without a
// network; the engine runs the actions exactly as it runs the app's requests.
//
// Feral's namespace (n is a source, snapshot or cue number as the app shows it):
//
//   /feral/go [CUE]                         GO: the next cue, or cue CUE
//   /feral/cue/{n}/go                       run cue n ("12.5" works)
//   /feral/stop                             stop every running fade
//   /feral/snapshot/{n}/recall [SECONDS]    recall snapshot n (over its own time, or SECONDS)
//   /feral/snapshot/store [NAME]            store every source as a new snapshot
//   /feral/save                             save the show
//   /feral/source/{n}/xyz X Y Z             move a source (metres, venue frame); also /xy X Y and /x, /y, /z
//   /feral/source/{n}/gain DB               also /mute 0|1, /width DEGREES, /lfe DB (or "off")
//   /feral/source/{n}/send/{group} DB       a send level, group by number or name
//   /feral/source/{n}/release               hand the source's position back to cues
//   /feral/subscribe [PORT] ["adm"]         send me every change (to PORT, else to where this came from)
//   /feral/unsubscribe [PORT]
//   /feral/ping                             answers /feral/pong
//
// ADM-OSC 1.0 (https://immersive-audio-live.github.io/ADM-OSC/), object n is source n:
//
//   /adm/obj/{n}/xyz X Y Z, /x, /y, /z      -1 to 1, mapped onto the show's ADM box
//   /adm/obj/{n}/aed AZ EL D, /azim, /elev, /dist
//   /adm/obj/{n}/gain LINEAR, /mute 0|1, /w 0-1 (width, 1 is 180 degrees)
//
// A position from OSC takes the source over from cues (see PositionOwner).

/// What the engine does for a message.
public enum ControlAction: Equatable {
    case go(cue: String?)
    case recall(snapshot: String, fadeSeconds: Double?)
    case stopFades
    case save
    /// Applies a command, as a client's request does.
    case apply(Command)
    /// Live values for sources. With an owner, the sources whose position it sets belong to it.
    case update([SourceUpdate], owner: PositionOwner?)
    /// Hands sources' positions back to cues.
    case release([UUID])
    /// Sends every change to the sender (or to `port` on the sender's address).
    case subscribe(port: Int?, adm: Bool)
    case unsubscribe(port: Int?)
    /// Answers the sender.
    case reply(OSCMessage)
}

public struct ControlMapper {
    public let state: ShowState

    public init(state: ShowState) {
        self.state = state
    }

    private var box: ADMBox { state.show.control.admBox }

    // MARK: OSC

    /// The actions for a message in Feral's or ADM-OSC's namespace. Throws, with a reason for the
    /// log, for anything else or anything malformed.
    public func actions(for m: OSCMessage) throws -> [ControlAction] {
        let p = m.parts.map(String.init)
        guard let root = p.first else { throw OSCError("an empty address") }
        switch root {
        case "feral": return try feral(Array(p.dropFirst()), m)
        case "adm": return try adm(Array(p.dropFirst()), m)
        default: throw OSCError("\(m.address) is not a Feral or ADM-OSC address")
        }
    }

    private func feral(_ p: [String], _ m: OSCMessage) throws -> [ControlAction] {
        let args = m.arguments
        switch (p.first ?? "", p.count) {
        case ("go", 1):
            return [.go(cue: args.first?.text)]
        case ("cue", 3) where p[2] == "go":
            return [.go(cue: p[1])]
        case ("stop", 1):
            return [.stopFades]
        case ("save", 1):
            return [.save]
        case ("ping", 1):
            return [.reply(OSCMessage("/feral/pong", args))]
        case ("snapshot", 3) where p[2] == "recall":
            let fade = try args.first.map { try seconds($0) }
            return [.recall(snapshot: p[1], fadeSeconds: fade)]
        case ("snapshot", 2) where p[1] == "store":
            let n = state.nextSnapshotNumber
            let name = args.first?.text ?? "Snapshot \(n)"
            return [.apply(.captureSnapshot(capture: SnapshotCapture(number: n, name: name)))]
        case ("subscribe", 1):
            return [.subscribe(port: try args.first(where: { $0.number != nil }).map { try port($0) },
                               adm: args.contains { $0.text?.lowercased() == "adm" })]
        case ("unsubscribe", 1):
            return [.unsubscribe(port: try args.first.map { try port($0) })]
        case ("source", 3...):
            return try source(p, m)
        default:
            throw OSCError("no Feral command \(m.address)")
        }
    }

    private func source(_ p: [String], _ m: OSCMessage) throws -> [ControlAction] {
        guard let n = Int(p[1]), let s = state.show.sources.first(where: { $0.number == n }) else {
            throw OSCError("\(m.address): no source \(p[1])")
        }
        let a = m.arguments
        var v = SourceValues()
        var claims = false
        switch (p[2], p.count) {
        case ("xyz", 4):
            try count(a, 3, m)
            v.position = Position(try num(a[0], m), try num(a[1], m), try num(a[2], m))
            claims = true
        case ("xy", 4):
            try count(a, 2, m)
            v.position = Position(try num(a[0], m), try num(a[1], m), s.position.z)
            claims = true
        case ("x", 4), ("y", 4), ("z", 4):
            try count(a, 1, m)
            var pos = s.position
            let x = try num(a[0], m)
            switch p[2] { case "x": pos.x = x; case "y": pos.y = x; default: pos.z = x }
            v.position = pos
            claims = true
        case ("gain", 4):
            try count(a, 1, m)
            v.gainDB = try num(a[0], m)
        case ("mute", 4):
            try count(a, 1, m)
            v.mute = try num(a[0], m) != 0
        case ("width", 4):
            try count(a, 1, m)
            v.width = try num(a[0], m)
        case ("lfe", 4):
            if a.isEmpty || a[0] == .none || a[0].text?.lowercased() == "off" {
                v.lfeOff = true
            } else {
                v.lfeDB = try num(a[0], m)
            }
        case ("send", 5):
            try count(a, 1, m)
            let key = p[3]
            guard let g = state.show.groups.first(where: { Int(key) == $0.number || $0.name.lowercased() == key.lowercased() }) else {
                throw OSCError("\(m.address): no group \(key)")
            }
            let db = try num(a[0], m)
            var sends = s.sends
            if let i = sends.firstIndex(where: { $0.group == g.id }) { sends[i].gainDB = db } else { sends.append(GroupSend(group: g.id, gainDB: db)) }
            v.sends = sends
        case ("release", 3):
            return [.release([s.id])]
        default:
            throw OSCError("no Feral command \(m.address)")
        }
        return [.update([SourceUpdate(id: s.id, values: v)], owner: claims ? .osc : nil)]
    }

    private func adm(_ p: [String], _ m: OSCMessage) throws -> [ControlAction] {
        guard p.count == 3, p[0] == "obj" else { throw OSCError("no ADM-OSC object command \(m.address)") }
        guard let n = Int(p[1]), let s = state.show.sources.first(where: { $0.number == n }) else {
            throw OSCError("\(m.address): no source \(p[1])")
        }
        let a = m.arguments
        let now = box.adm(s.position)
        var v = SourceValues()
        var claims = true
        switch p[2] {
        case "xyz":
            try count(a, 3, m)
            v.position = box.position(adm: try num(a[0], m), try num(a[1], m), try num(a[2], m))
        case "x", "y", "z":
            try count(a, 1, m)
            var c = now
            let x = try num(a[0], m)
            switch p[2] { case "x": c.x = x; case "y": c.y = x; default: c.z = x }
            v.position = box.position(adm: c.x, c.y, c.z)
        case "aed", "azim", "elev", "dist":
            var polar = ADMBox.polar(x: now.x, y: now.y, z: now.z)
            if p[2] == "aed" {
                try count(a, 3, m)
                polar = (try num(a[0], m), try num(a[1], m), try num(a[2], m))
            } else {
                try count(a, 1, m)
                let x = try num(a[0], m)
                switch p[2] { case "azim": polar.azimuth = x; case "elev": polar.elevation = x; default: polar.distance = x }
            }
            let c = ADMBox.cartesian(azimuth: polar.azimuth, elevation: polar.elevation, distance: polar.distance)
            v.position = box.position(adm: c.x, c.y, c.z)
        case "gain":
            try count(a, 1, m)
            let g = try num(a[0], m)
            v.gainDB = g <= 0 ? -144 : 20 * log10(g)
            claims = false
        case "mute":
            try count(a, 1, m)
            v.mute = try num(a[0], m) != 0
            claims = false
        case "w":
            try count(a, 1, m)
            v.width = min(max(try num(a[0], m), 0), 1) * 180
            claims = false
        case "name", "dref", "dmax", "lock", "config":
            return [] // accepted, not used
        default:
            throw OSCError("no ADM-OSC object command \(m.address)")
        }
        return [.update([SourceUpdate(id: s.id, values: v)], owner: claims ? .osc : nil)]
    }

    private func count(_ a: [OSCValue], _ n: Int, _ m: OSCMessage) throws {
        guard a.count >= n else { throw OSCError("\(m.address) needs \(n) number(s)") }
    }

    private func num(_ v: OSCValue, _ m: OSCMessage) throws -> Double {
        guard let n = v.number, n.isFinite else { throw OSCError("\(m.address): \(v.text ?? "an argument") is not a number") }
        return n
    }

    private func seconds(_ v: OSCValue) throws -> Double {
        guard let n = v.number, n.isFinite, (0...3600).contains(n) else { throw OSCError("a fade time must be from 0 to 3600 s") }
        return n
    }

    private func port(_ v: OSCValue) throws -> Int {
        guard let n = v.number, n == n.rounded(), (1...65_535).contains(n) else { throw OSCError("a port must be from 1 to 65535") }
        return Int(n)
    }

    // MARK: The trigger map and MSC

    /// The actions of the enabled triggers an OSC message matches.
    public func triggered(by m: OSCMessage) -> [ControlAction] {
        let value = m.arguments.first?.text
        return run { input in
            guard case .osc(let address, let want) = input, address == m.address else { return nil }
            if let want, want != value { return nil }
            return .some(value)
        }
    }

    /// The actions for a MIDI message: the triggers it matches, then, for MIDI Show Control sent to
    /// this engine with no trigger of its own, GO, STOP and RESUME.
    public func triggered(by m: MIDIMessage) -> [ControlAction] {
        let actions = run { input in
            switch (input, m) {
            case (.midiProgram(let c, let p), .programChange(let mc, let mp)):
                return match(c, mc) && match(p, mp) ? .some(String(mp)) : nil
            case (.midiNote(let c, let n), .noteOn(let mc, let mn, _)):
                return match(c, mc) && match(n, mn) ? .some(String(mn)) : nil
            case (.midiControl(let c, let cc, let v), .controlChange(let mc, let mcc, let mv)):
                return match(c, mc) && cc == mcc && match(v, mv) ? .some(String(mv)) : nil
            case (.msc(let cmd, let cue), .showControl(let msc)):
                guard forMe(msc), cmd == nil || cmd == msc.command, cue == nil || cue == msc.cue else { return nil }
                return .some(msc.cue)
            default:
                return nil
            }
        }
        guard actions.isEmpty, case .showControl(let msc) = m, forMe(msc) else { return actions }
        switch msc.command {
        case .go, .timedGo, .resume: return [.go(cue: msc.cue)]
        case .stop, .allOff, .goOff: return [.stopFades]
        default: return []
        }
    }

    private func match(_ want: Int?, _ got: Int) -> Bool { want == nil || want == got }

    private func forMe(_ m: MSCMessage) -> Bool {
        guard let id = state.show.control.mscDeviceID else { return true }
        return m.deviceID == 127 || m.deviceID == id
    }

    /// Runs `matches` over the enabled triggers: it returns nil for no match, or the value "{value}"
    /// stands for.
    private func run(_ matches: (TriggerInput) -> String??) -> [ControlAction] {
        state.show.control.triggers.filter(\.enabled).compactMap { t -> ControlAction? in
            guard let value = matches(t.on) else { return nil }
            switch t.action.filled(with: value) {
            case .go(let cue): return .go(cue: cue)
            case .recall(let s, let f): return .recall(snapshot: s, fadeSeconds: f)
            case .stop: return .stopFades
            }
        }
    }

    // MARK: Echo

    /// What subscribers hear when a command is applied: the values it changed, in Feral's namespace
    /// or in ADM-OSC's. `state` is the show after the command.
    public func echo(_ command: Command, adm: Bool) -> [OSCMessage] {
        switch command {
        case .updateSources(let updates):
            return updates.flatMap { u -> [OSCMessage] in
                guard let s = state.source(u.id) else { return [] }
                return echo(s, u.values, adm: adm)
            }
        case .setSource(let s):
            return echo(s, state.values(of: s), adm: adm)
        default:
            return []
        }
    }

    /// Every source's values and the cue list position, for a new subscriber.
    public func dump(adm: Bool, status: EngineStatus?) -> [OSCMessage] {
        state.show.sources.flatMap { echo($0, state.values(of: $0), adm: adm) } + (adm ? [] : cueMessages(status))
    }

    /// /feral/cue/current and /feral/cue/next: the cue numbers ("" for none) and names.
    public func cueMessages(_ status: EngineStatus?) -> [OSCMessage] {
        func cue(_ id: UUID?) -> [OSCValue] {
            guard let c = id.flatMap({ state.cue($0) }) else { return [.string(""), .string("")] }
            return [.string(c.number), .string(c.name ?? "")]
        }
        return [OSCMessage("/feral/cue/current", cue(status?.currentCue)), OSCMessage("/feral/cue/next", cue(status?.nextCue))]
    }

    private func echo(_ s: Source, _ v: SourceValues, adm: Bool) -> [OSCMessage] {
        var out: [OSCMessage] = []
        let base = adm ? "/adm/obj/\(s.number)" : "/feral/source/\(s.number)"
        if v.position != nil {
            if adm {
                let c = box.adm(s.position)
                out.append(OSCMessage(base + "/xyz", [.float(Float(c.x)), .float(Float(c.y)), .float(Float(c.z))]))
            } else {
                out.append(OSCMessage(base + "/xyz", [.float(Float(s.position.x)), .float(Float(s.position.y)), .float(Float(s.position.z))]))
            }
        }
        if v.gainDB != nil {
            out.append(OSCMessage(base + "/gain", [.float(Float(adm ? pow(10, s.gainDB / 20) : s.gainDB))]))
        }
        if v.mute != nil { out.append(OSCMessage(base + "/mute", [.int(s.mute ? 1 : 0)])) }
        if v.width != nil { out.append(OSCMessage(base + (adm ? "/w" : "/width"), [.float(Float(adm ? s.width / 180 : s.width))])) }
        guard !adm else { return out }
        if let sends = v.sends {
            for send in sends {
                guard let g = state.group(send.group) else { continue }
                out.append(OSCMessage(base + "/send/\(g.number)", [.float(Float(send.gainDB))]))
            }
        }
        if v.lfeDB != nil || v.lfeOff != nil {
            out.append(OSCMessage(base + "/lfe", [s.lfeDB.map { OSCValue.float(Float($0)) } ?? OSCValue.string("off")]))
        }
        return out
    }
}

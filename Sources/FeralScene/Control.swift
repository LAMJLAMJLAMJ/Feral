import Foundation

// How the outside world drives the show (milestone 4): the box ADM-OSC's normalised coordinates are
// mapped onto, the trigger map that turns console and QLab messages into cues, and which MIDI Show
// Control device id the engine answers to. They are saved in show.json under "control", because they
// belong to the show (a console's snapshot list belongs to the production), not to the Mac.

/// Who moves a source's position now. Each source has one owner at a time and the newest one takes
/// over, so QLab and a cue never fight over the same source: while QLab (OSC) owns a source, cues and
/// snapshots leave its position alone (they still set its gain, mute and sends) until the source is
/// handed back, by a cue with `reclaim` on, by the app, or by /feral/source/{n}/release.
public enum PositionOwner: String, Codable, CaseIterable, Equatable {
    /// Cues and snapshots, the app and feral-cli. Every source starts here.
    case cues
    /// Live OSC or ADM-OSC: QLab, a console, a panner plugin.
    case osc
    /// A tracking system (milestone 5).
    case tracking

    /// "cues", "OSC (QLab)", "tracking", for people.
    public var label: String {
        switch self {
        case .cues: return "cues"
        case .osc: return "OSC (QLab)"
        case .tracking: return "tracking"
        }
    }
}

/// The box in the venue that ADM-OSC's -1 to 1 coordinates span. ADM-OSC is listener-centred: x runs
/// from the audience's left (-1) to their right (+1), y from the back (-1) to the front, towards the
/// stage (+1), and z from the floor (-1) to the top (+1). In Feral's venue frame (x to stage right, y
/// towards the audience) the audience's left is +x and the front is -y, so ADM x = -1 lands on
/// `max.x` and ADM y = +1 on `min.y`.
public struct ADMBox: Codable, Equatable {
    public var min: Position
    public var max: Position

    public init(min: Position = Position(-10, -2, 0), max: Position = Position(10, 20, 10)) {
        self.min = min; self.max = max
    }

    /// The venue position for ADM-OSC cartesian coordinates (each clamped to -1...1).
    public func position(adm x: Double, _ y: Double, _ z: Double) -> Position {
        func t(_ v: Double) -> Double { (Swift.min(Swift.max(v, -1), 1) + 1) / 2 }
        return Position(max.x + (min.x - max.x) * t(x),
                        max.y + (min.y - max.y) * t(y),
                        min.z + (max.z - min.z) * t(z))
    }

    /// ADM-OSC cartesian coordinates (-1...1) for a venue position, the inverse of position(adm:).
    public func adm(_ p: Position) -> (x: Double, y: Double, z: Double) {
        func u(_ v: Double, _ from: Double, _ to: Double) -> Double {
            guard to != from else { return 0 }
            return Swift.min(Swift.max((v - from) / (to - from) * 2 - 1, -1), 1)
        }
        return (u(p.x, max.x, min.x), u(p.y, max.y, min.y), u(p.z, min.z, max.z))
    }

    /// ADM-OSC polar coordinates to its cartesian ones: azimuth in degrees with 0 at the front and
    /// positive to the left, elevation in degrees up, distance 0 to 1.
    public static func cartesian(azimuth: Double, elevation: Double, distance: Double) -> (x: Double, y: Double, z: Double) {
        let a = azimuth * Double.pi / 180, e = elevation * Double.pi / 180
        return (-sin(a) * cos(e) * distance, cos(a) * cos(e) * distance, sin(e) * distance)
    }

    /// The inverse of cartesian(azimuth:elevation:distance:).
    public static func polar(x: Double, y: Double, z: Double) -> (azimuth: Double, elevation: Double, distance: Double) {
        let d = (x * x + y * y + z * z).squareRoot()
        guard d > 0 else { return (0, 0, 0) }
        return (atan2(-x, y) * 180 / Double.pi, asin(Swift.min(Swift.max(z / d, -1), 1)) * 180 / Double.pi, d)
    }

    func check() throws {
        for v in [min.x, min.y, min.z, max.x, max.y, max.z] where !v.isFinite || abs(v) > 10_000 {
            throw ConfigError("the ADM-OSC box must be finite and within 10 km")
        }
        guard min.x != max.x, min.y != max.y, min.z != max.z else {
            throw ConfigError("the ADM-OSC box needs some size on every axis")
        }
    }
}

/// MIDI Show Control commands (the ones a cue engine answers).
public enum MSCCommand: String, Codable, CaseIterable, Equatable {
    case go, stop, resume, timedGo, set, fire, allOff, restore, reset, goOff
}

/// What a trigger listens for. A field left out matches anything.
public enum TriggerInput: Codable, Equatable {
    /// An OSC message to this address (exactly, without wildcards). `value` matches the first argument,
    /// written as text ("5", "5.5", "Act 1").
    case osc(address: String, value: String?)
    /// A program change, from 1 to 128 as consoles number them. `channel` is 1 to 16.
    case midiProgram(channel: Int?, program: Int?)
    /// A note on (velocity above 0), note 0 to 127.
    case midiNote(channel: Int?, note: Int?)
    /// A control change; `value` 0 to 127.
    case midiControl(channel: Int?, controller: Int, value: Int?)
    /// A MIDI Show Control command, with its cue number ("12.5").
    case msc(command: MSCCommand?, cue: String?)
}

/// What a trigger does. In `cue` and `snapshot`, "{value}" is replaced by the incoming value: the
/// program number (1 to 128), note, controller value, MSC cue number or OSC first argument, so one
/// trigger can map every console snapshot to the cue with the same number.
public enum TriggerAction: Codable, Equatable {
    /// Runs a cue, or with none the next one.
    case go(cue: String?)
    /// Recalls a snapshot (by number or name) over a fade (none: its own time).
    case recall(snapshot: String, fadeSeconds: Double?)
    /// Stops every running fade.
    case stop
}

/// One row of the trigger map: message in, action out.
public struct Trigger: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String?
    public var enabled: Bool
    public var on: TriggerInput
    public var action: TriggerAction

    public init(id: UUID = UUID(), name: String? = nil, enabled: Bool = true, on: TriggerInput, action: TriggerAction) {
        self.id = id; self.name = name; self.enabled = enabled; self.on = on; self.action = action
    }

    enum CodingKeys: String, CodingKey { case id, name, enabled, on, action }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        on = try c.decode(TriggerInput.self, forKey: .on)
        action = try c.decode(TriggerAction.self, forKey: .action)
    }

    func check() throws {
        func range(_ v: Int?, _ r: ClosedRange<Int>, _ what: String) throws {
            if let v, !r.contains(v) { throw ConfigError("trigger \(label): \(what) must be from \(r.lowerBound) to \(r.upperBound)") }
        }
        switch on {
        case .osc(let address, _):
            guard address.hasPrefix("/") else { throw ConfigError("trigger \(label): an OSC address starts with /") }
        case .midiProgram(let ch, let p):
            try range(ch, 1...16, "channel"); try range(p, 1...128, "program")
        case .midiNote(let ch, let n):
            try range(ch, 1...16, "channel"); try range(n, 0...127, "note")
        case .midiControl(let ch, let cc, let v):
            try range(ch, 1...16, "channel"); try range(cc, 0...127, "controller"); try range(v, 0...127, "value")
        case .msc:
            break
        }
        if case .recall(_, let f?) = action, !(0...3600).contains(f) {
            throw ConfigError("trigger \(label): fadeSeconds must be from 0 to 3600")
        }
    }

    /// Its name, or what it listens for.
    public var label: String { name ?? on.description }
}

extension TriggerInput: CustomStringConvertible {
    public var description: String {
        func ch(_ c: Int?) -> String { c.map { " on channel \($0)" } ?? "" }
        switch self {
        case .osc(let a, let v): return "OSC \(a)" + (v.map { " \($0)" } ?? "")
        case .midiProgram(let c, let p): return "program change " + (p.map(String.init) ?? "(any)") + ch(c)
        case .midiNote(let c, let n): return "note " + (n.map(String.init) ?? "(any)") + ch(c)
        case .midiControl(let c, let cc, let v): return "CC \(cc)" + (v.map { " = \($0)" } ?? "") + ch(c)
        case .msc(let cmd, let q): return "MSC " + (cmd?.rawValue ?? "(any)") + (q.map { " cue \($0)" } ?? "")
        }
    }
}

extension TriggerAction: CustomStringConvertible {
    public var description: String {
        switch self {
        case .go(let c): return c.map { "GO cue \($0)" } ?? "GO (next cue)"
        case .recall(let s, let f): return "recall snapshot \(s)" + (f.map { " over \($0) s" } ?? "")
        case .stop: return "stop fades"
        }
    }

    /// The action with "{value}" replaced.
    public func filled(with value: String?) -> TriggerAction {
        func fill(_ s: String) -> String { s.replacingOccurrences(of: "{value}", with: value ?? "") }
        switch self {
        case .go(let c): return .go(cue: c.map(fill))
        case .recall(let s, let f): return .recall(snapshot: fill(s), fadeSeconds: f)
        case .stop: return .stop
        }
    }
}

/// show.json's "control": the ADM-OSC box, the trigger map and the MSC device id.
public struct ControlSettings: Codable, Equatable {
    public var admBox: ADMBox
    public var triggers: [Trigger]
    /// The MSC device id the engine answers to (0 to 111); none answers every id. Messages sent to
    /// the all-call id (127) are always answered.
    public var mscDeviceID: Int?

    public init(admBox: ADMBox = ADMBox(), triggers: [Trigger] = [], mscDeviceID: Int? = nil) {
        self.admBox = admBox; self.triggers = triggers; self.mscDeviceID = mscDeviceID
    }

    enum CodingKeys: String, CodingKey { case admBox, triggers, mscDeviceID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        admBox = try c.decodeIfPresent(ADMBox.self, forKey: .admBox) ?? ADMBox()
        triggers = try c.decodeIfPresent([Trigger].self, forKey: .triggers) ?? []
        mscDeviceID = try c.decodeIfPresent(Int.self, forKey: .mscDeviceID)
    }

    public func check() throws {
        try admBox.check()
        for t in triggers { try t.check() }
        if let id = mscDeviceID, !(0...111).contains(id) { throw ConfigError("mscDeviceID must be from 0 to 111") }
    }
}

extension Snapshot {
    /// The snapshot without the positions of `sources`, which something live owns: a recall still
    /// sets their other values.
    public func withoutPositions(of sources: Set<UUID>) -> Snapshot {
        guard !sources.isEmpty else { return self }
        var s = self
        for i in s.sources.indices where sources.contains(s.sources[i].id) { s.sources[i].values.position = nil }
        s.sources.removeAll { $0.values.isEmpty }
        return s
    }
}

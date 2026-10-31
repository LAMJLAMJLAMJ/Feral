import Foundation

// The show: one scene (sources, speakers, groups) plus the snapshots and cues that change it. It is
// saved as a .feralshow package (see ShowFile.swift): show.json holds the sources, groups, snapshots
// and cues; system.json holds the speakers, the system tech's layer that snapshots and cues never
// touch. Every object has a stable UUID, which the file uses for references, and a number for
// people and for OSC addresses, so renumbering never breaks a cue.

/// The schema the show and system files are written with. Older files are migrated on load; newer
/// ones are refused.
public let showSchema = 1

/// A source's send to one speaker group.
public struct GroupSend: Codable, Equatable, Hashable {
    public var group: UUID
    public var gainDB: Double

    public init(group: UUID, gainDB: Double = 0) {
        self.group = group; self.gainDB = gainDB
    }
}

/// A source: an engine input placed in the venue and sent to speaker groups.
public struct Source: Codable, Equatable, Identifiable {
    public var id: UUID
    public var number: Int
    public var name: String?
    /// Engine input, from 1.
    public var input: Int
    public var position: Position
    public var gainDB: Double
    public var mute: Bool
    /// Spread in degrees (VBAP groups).
    public var width: Double
    /// "#RRGGBB" for the app; none picks one from the number.
    public var colour: String?
    /// The groups it plays through, each at a send level. Empty: it plays nowhere.
    public var sends: [GroupSend]
    /// Send to the LFE speakers in dB; none sends nothing.
    public var lfeDB: Double?

    public init(id: UUID = UUID(), number: Int, name: String? = nil, input: Int, position: Position, gainDB: Double = 0,
                mute: Bool = false, width: Double = 0, colour: String? = nil, sends: [GroupSend] = [], lfeDB: Double? = nil) {
        self.id = id; self.number = number; self.name = name; self.input = input; self.position = position
        self.gainDB = gainDB; self.mute = mute; self.width = width; self.colour = colour; self.sends = sends; self.lfeDB = lfeDB
    }

    enum CodingKeys: String, CodingKey { case id, number, name, input, position, gainDB, mute, width, colour, sends, lfeDB }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        input = try c.decode(Int.self, forKey: .input)
        number = try c.decodeIfPresent(Int.self, forKey: .number) ?? input
        name = try c.decodeIfPresent(String.self, forKey: .name)
        position = try c.decode(Position.self, forKey: .position)
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        mute = try c.decodeIfPresent(Bool.self, forKey: .mute) ?? false
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0
        colour = try c.decodeIfPresent(String.self, forKey: .colour)
        sends = try c.decodeIfPresent([GroupSend].self, forKey: .sends) ?? []
        lfeDB = try c.decodeIfPresent(Double.self, forKey: .lfeDB)
    }

    /// "12 Vox" or "12".
    public var label: String { name.map { "\(number) \($0)" } ?? "\(number)" }
}

/// A speaker and its system layer: alignment delay, EQ, trim, polarity, limiter and mute.
public struct Speaker: Codable, Equatable, Identifiable {
    public var id: UUID
    public var number: Int
    public var name: String?
    /// Engine output, from 1.
    public var output: Int
    public var position: Position
    /// A label for people: "K2", "sub", "front fill".
    public var type: String?
    public var delayMS: Double
    public var trimDB: Double
    public var invert: Bool
    public var mute: Bool
    public var eq: [EQBand]
    public var limiterDB: Double?
    public var limiterReleaseMS: Double

    public init(id: UUID = UUID(), number: Int, name: String? = nil, output: Int, position: Position, type: String? = nil,
                delayMS: Double = 0, trimDB: Double = 0, invert: Bool = false, mute: Bool = false, eq: [EQBand] = [],
                limiterDB: Double? = nil, limiterReleaseMS: Double = 200) {
        self.id = id; self.number = number; self.name = name; self.output = output; self.position = position
        self.type = type; self.delayMS = delayMS; self.trimDB = trimDB; self.invert = invert; self.mute = mute
        self.eq = eq; self.limiterDB = limiterDB; self.limiterReleaseMS = limiterReleaseMS
    }

    enum CodingKeys: String, CodingKey {
        case id, number, name, output, position, type, delayMS, trimDB, invert, mute, eq, limiterDB, limiterReleaseMS
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        output = try c.decode(Int.self, forKey: .output)
        number = try c.decodeIfPresent(Int.self, forKey: .number) ?? output
        name = try c.decodeIfPresent(String.self, forKey: .name)
        position = try c.decode(Position.self, forKey: .position)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        delayMS = try c.decodeIfPresent(Double.self, forKey: .delayMS) ?? 0
        trimDB = try c.decodeIfPresent(Double.self, forKey: .trimDB) ?? 0
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        mute = try c.decodeIfPresent(Bool.self, forKey: .mute) ?? false
        eq = try c.decodeIfPresent([EQBand].self, forKey: .eq) ?? []
        limiterDB = try c.decodeIfPresent(Double.self, forKey: .limiterDB)
        limiterReleaseMS = try c.decodeIfPresent(Double.self, forKey: .limiterReleaseMS) ?? 200
    }

    /// "3 Main L" or "3".
    public var label: String { name.map { "\(number) \($0)" } ?? "\(number)" }

    /// As the renderer takes it.
    public var config: SpeakerConfig {
        SpeakerConfig(output: output, name: name, position: position, delayMS: delayMS, trimDB: trimDB, invert: invert,
                      mute: mute, eq: eq, limiterDB: limiterDB, limiterReleaseMS: limiterReleaseMS)
    }
}

/// A speaker group and its renderer. Only the keys for its renderer are used (see GroupConfig).
public struct SpeakerGroup: Codable, Equatable, Identifiable {
    public var id: UUID
    public var number: Int
    public var name: String
    public var renderer: Renderer
    /// Its speakers, by id.
    public var speakers: [UUID]
    public var gainDB: Double
    /// Per-speaker level in the group, by speaker id.
    public var weightsDB: [String: Double]
    public var colour: String?
    public var precedenceMS: Double
    public var rolloff: Double
    public var referenceDistance: Double?
    public var distanceOffset: Double?
    public var reference: Position?
    public var dimensions: Int?
    public var blur: Double
    public var rolloffDB: Double

    public init(id: UUID = UUID(), number: Int, name: String, renderer: Renderer, speakers: [UUID], gainDB: Double = 0,
                weightsDB: [String: Double] = [:], colour: String? = nil, precedenceMS: Double = 10, rolloff: Double = 1,
                referenceDistance: Double? = nil, distanceOffset: Double? = nil, reference: Position? = nil,
                dimensions: Int? = nil, blur: Double = 0.5, rolloffDB: Double = 6) {
        self.id = id; self.number = number; self.name = name; self.renderer = renderer; self.speakers = speakers
        self.gainDB = gainDB; self.weightsDB = weightsDB; self.colour = colour; self.precedenceMS = precedenceMS
        self.rolloff = rolloff; self.referenceDistance = referenceDistance; self.distanceOffset = distanceOffset
        self.reference = reference; self.dimensions = dimensions; self.blur = blur; self.rolloffDB = rolloffDB
    }

    enum CodingKeys: String, CodingKey {
        case id, number, name, renderer, speakers, gainDB, weightsDB, colour, precedenceMS, rolloff, referenceDistance,
             distanceOffset, reference, dimensions, blur, rolloffDB
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SpeakerGroup(number: 0, name: "", renderer: .delay, speakers: [])
        id = try c.decode(UUID.self, forKey: .id)
        number = try c.decode(Int.self, forKey: .number)
        name = try c.decode(String.self, forKey: .name)
        renderer = try c.decode(Renderer.self, forKey: .renderer)
        speakers = try c.decodeIfPresent([UUID].self, forKey: .speakers) ?? []
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? d.gainDB
        weightsDB = try c.decodeIfPresent([String: Double].self, forKey: .weightsDB) ?? d.weightsDB
        colour = try c.decodeIfPresent(String.self, forKey: .colour)
        precedenceMS = try c.decodeIfPresent(Double.self, forKey: .precedenceMS) ?? d.precedenceMS
        rolloff = try c.decodeIfPresent(Double.self, forKey: .rolloff) ?? d.rolloff
        referenceDistance = try c.decodeIfPresent(Double.self, forKey: .referenceDistance)
        distanceOffset = try c.decodeIfPresent(Double.self, forKey: .distanceOffset)
        reference = try c.decodeIfPresent(Position.self, forKey: .reference)
        dimensions = try c.decodeIfPresent(Int.self, forKey: .dimensions)
        blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? d.blur
        rolloffDB = try c.decodeIfPresent(Double.self, forKey: .rolloffDB) ?? d.rolloffDB
    }
}

/// How a fade moves from the old value to the new one over its time.
public enum FadeCurve: String, Codable, CaseIterable, Equatable {
    /// Straight.
    case linear
    /// Starts and ends gently.
    case sCurve
    /// Starts slowly and finishes fast.
    case exponential

    /// The fraction of the way from old to new at a fraction `t` (0 to 1) of the fade's time.
    public func apply(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch self {
        case .linear: return t
        case .sCurve: return 0.5 - 0.5 * cos(Double.pi * t)
        case .exponential: return (pow(2, 10 * t) - 1) / 1023
        }
    }
}

/// Some or all of a source's live values: what a snapshot stores and what a move or fade step changes.
/// A missing value is left as it is.
public struct SourceValues: Codable, Equatable {
    public var position: Position?
    public var gainDB: Double?
    public var mute: Bool?
    public var width: Double?
    public var sends: [GroupSend]?
    public var lfeDB: Double?
    /// True turns the LFE send off (lfeDB is then ignored).
    public var lfeOff: Bool?

    public init(position: Position? = nil, gainDB: Double? = nil, mute: Bool? = nil, width: Double? = nil,
                sends: [GroupSend]? = nil, lfeDB: Double? = nil, lfeOff: Bool? = nil) {
        self.position = position; self.gainDB = gainDB; self.mute = mute; self.width = width
        self.sends = sends; self.lfeDB = lfeDB; self.lfeOff = lfeOff
    }

    /// These values with `newer`'s on top.
    public func merged(with newer: SourceValues) -> SourceValues {
        var v = self
        if let p = newer.position { v.position = p }
        if let g = newer.gainDB { v.gainDB = g }
        if let m = newer.mute { v.mute = m }
        if let w = newer.width { v.width = w }
        if let s = newer.sends { v.sends = s }
        if newer.lfeOff == true { v.lfeOff = true; v.lfeDB = nil } else if let l = newer.lfeDB { v.lfeDB = l; v.lfeOff = nil }
        return v
    }

    public var isEmpty: Bool { self == SourceValues() }
}

/// New values for one source.
public struct SourceUpdate: Codable, Equatable {
    public var id: UUID
    public var values: SourceValues

    public init(id: UUID, values: SourceValues) {
        self.id = id; self.values = values
    }
}

/// The source values a snapshot can store.
public enum SnapshotField: String, Codable, CaseIterable, Equatable {
    case position, gain, mute, width, sends, lfe
}

/// Stored source values, recalled with a fade. It holds only what its scope included when stored:
/// some sources, and for each some fields.
public struct Snapshot: Codable, Equatable, Identifiable {
    public var id: UUID
    public var number: Int
    public var name: String
    /// The fade a recall takes when the cue or command gives none.
    public var fadeSeconds: Double
    public var curve: FadeCurve
    public var sources: [SourceUpdate]

    public init(id: UUID = UUID(), number: Int, name: String, fadeSeconds: Double = 0, curve: FadeCurve = .linear,
                sources: [SourceUpdate] = []) {
        self.id = id; self.number = number; self.name = name; self.fadeSeconds = fadeSeconds
        self.curve = curve; self.sources = sources
    }

    enum CodingKeys: String, CodingKey { case id, number, name, fadeSeconds, curve, sources }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        number = try c.decode(Int.self, forKey: .number)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Snapshot \(number)"
        fadeSeconds = try c.decodeIfPresent(Double.self, forKey: .fadeSeconds) ?? 0
        curve = try c.decodeIfPresent(FadeCurve.self, forKey: .curve) ?? .linear
        sources = try c.decodeIfPresent([SourceUpdate].self, forKey: .sources) ?? []
    }

    /// "3 Act 1 open".
    public var label: String { "\(number) \(name)" }
}

/// What to store in a snapshot: an id and number for it, and its scope.
public struct SnapshotCapture: Codable, Equatable {
    /// An existing snapshot's id updates it; a new one adds a snapshot.
    public var id: UUID
    public var number: Int
    public var name: String
    /// None: every source.
    public var sources: [UUID]?
    /// None: every field.
    public var fields: [SnapshotField]?
    public var fadeSeconds: Double
    public var curve: FadeCurve

    public init(id: UUID = UUID(), number: Int, name: String, sources: [UUID]? = nil, fields: [SnapshotField]? = nil,
                fadeSeconds: Double = 0, curve: FadeCurve = .linear) {
        self.id = id; self.number = number; self.name = name; self.sources = sources; self.fields = fields
        self.fadeSeconds = fadeSeconds; self.curve = curve
    }
}

/// A cue in the show's cue list, numbered like QLab's ("12", "12.5").
public struct Cue: Codable, Equatable, Identifiable {
    public var id: UUID
    public var number: String
    public var name: String?
    /// The snapshot it recalls; none makes it a marker that only moves the list on.
    public var snapshot: UUID?
    /// None: the snapshot's own fade time.
    public var fadeSeconds: Double?
    public var curve: FadeCurve?
    /// Go to the next cue as soon as this one's fade is over.
    public var autoFollow: Bool
    /// Hand the snapshot's sources back to cues first, so it moves them even where QLab or tracking
    /// had taken them over (see PositionOwner).
    public var reclaim: Bool

    public init(id: UUID = UUID(), number: String, name: String? = nil, snapshot: UUID? = nil, fadeSeconds: Double? = nil,
                curve: FadeCurve? = nil, autoFollow: Bool = false, reclaim: Bool = false) {
        self.id = id; self.number = number; self.name = name; self.snapshot = snapshot; self.fadeSeconds = fadeSeconds
        self.curve = curve; self.autoFollow = autoFollow; self.reclaim = reclaim
    }

    enum CodingKeys: String, CodingKey { case id, number, name, snapshot, fadeSeconds, curve, autoFollow, reclaim }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        if let n = try? c.decode(Double.self, forKey: .number) {
            number = n == n.rounded() ? String(Int(n)) : String(n)
        } else {
            number = try c.decode(String.self, forKey: .number)
        }
        name = try c.decodeIfPresent(String.self, forKey: .name)
        snapshot = try c.decodeIfPresent(UUID.self, forKey: .snapshot)
        fadeSeconds = try c.decodeIfPresent(Double.self, forKey: .fadeSeconds)
        curve = try c.decodeIfPresent(FadeCurve.self, forKey: .curve)
        autoFollow = try c.decodeIfPresent(Bool.self, forKey: .autoFollow) ?? false
        reclaim = try c.decodeIfPresent(Bool.self, forKey: .reclaim) ?? false
    }

    /// The number as a value to sort by: "12.5" after "12" and before "13".
    public var order: Double { Double(number) ?? .infinity }

    /// "12.5 Storm" or "12.5".
    public var label: String { name.map { "\(number) \($0)" } ?? number }
}

/// show.json: the sources, groups, snapshots and cues, and how OSC, MIDI and consoles drive them.
public struct Show: Codable, Equatable {
    public var schema: Int
    public var name: String
    public var sources: [Source]
    public var groups: [SpeakerGroup]
    public var snapshots: [Snapshot]
    public var cues: [Cue]
    public var control: ControlSettings

    public init(name: String, sources: [Source] = [], groups: [SpeakerGroup] = [], snapshots: [Snapshot] = [],
                cues: [Cue] = [], control: ControlSettings = ControlSettings()) {
        schema = showSchema
        self.name = name; self.sources = sources; self.groups = groups; self.snapshots = snapshots; self.cues = cues
        self.control = control
    }

    enum CodingKeys: String, CodingKey { case schema, name, sources, groups, snapshots, cues, control }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? showSchema
        guard schema <= showSchema else {
            throw ConfigError("show.json has schema \(schema), but this Feral reads up to \(showSchema): update Feral")
        }
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        sources = try c.decodeIfPresent([Source].self, forKey: .sources) ?? []
        groups = try c.decodeIfPresent([SpeakerGroup].self, forKey: .groups) ?? []
        snapshots = try c.decodeIfPresent([Snapshot].self, forKey: .snapshots) ?? []
        cues = try c.decodeIfPresent([Cue].self, forKey: .cues) ?? []
        control = try c.decodeIfPresent(ControlSettings.self, forKey: .control) ?? ControlSettings()
        // Migrations from older schemas go here, oldest first.
        schema = showSchema
    }
}

/// system.json: the speakers and which of them take the sources' LFE sends.
public struct SystemLayer: Codable, Equatable {
    public var schema: Int
    public var speakers: [Speaker]
    /// The speakers a source's lfeDB send feeds.
    public var lfeSpeakers: [UUID]

    public init(speakers: [Speaker] = [], lfeSpeakers: [UUID] = []) {
        schema = showSchema
        self.speakers = speakers; self.lfeSpeakers = lfeSpeakers
    }

    enum CodingKeys: String, CodingKey { case schema, speakers, lfeSpeakers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? showSchema
        guard schema <= showSchema else {
            throw ConfigError("system.json has schema \(schema), but this Feral reads up to \(showSchema): update Feral")
        }
        speakers = try c.decodeIfPresent([Speaker].self, forKey: .speakers) ?? []
        lfeSpeakers = try c.decodeIfPresent([UUID].self, forKey: .lfeSpeakers) ?? []
        schema = showSchema
    }
}

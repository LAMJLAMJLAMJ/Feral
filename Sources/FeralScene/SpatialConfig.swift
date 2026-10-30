import FeralCore
import Foundation

// The spatial part of engine.json: speakers, speaker groups and sources. In milestone 3 these move
// into the show file; until then engine.json holds them so the renderers can be played on a rig.
// Positions are in metres in the venue frame: x to stage right, y towards the audience, z up,
// origin at stage centre on the stage floor.

/// A point in the venue, written [x, y, z] in metres.
public struct Position: Codable, Equatable {
    public var x: Double, y: Double, z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x; self.y = y; self.z = z
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
        z = try c.isAtEnd ? 0 : c.decode(Double.self)
        guard c.isAtEnd else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "a position is [x, y, z] in metres")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x); try c.encode(y); try c.encode(z)
    }

    public func distance(to o: Position) -> Double { ((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y) + (z - o.z) * (z - o.z)).squareRoot() }

    var c: feral_point { feral_point(x: x, y: y, z: z) }
}

public enum EQType: String, Codable, Equatable {
    case peak, lowShelf, highShelf, lowPass, highPass, notch, allPass

    var code: Int32 {
        switch self {
        case .peak: return Int32(FERAL_EQ_PEAK)
        case .lowShelf: return Int32(FERAL_EQ_LOW_SHELF)
        case .highShelf: return Int32(FERAL_EQ_HIGH_SHELF)
        case .lowPass: return Int32(FERAL_EQ_LOW_PASS)
        case .highPass: return Int32(FERAL_EQ_HIGH_PASS)
        case .notch: return Int32(FERAL_EQ_NOTCH)
        case .allPass: return Int32(FERAL_EQ_ALL_PASS)
        }
    }

    /// Q when none is given: 1 for a peak or notch, 0.7071 (Butterworth, no overshoot) otherwise.
    var defaultQ: Double { self == .peak || self == .notch ? 1 : 0.7071 }
}

/// One EQ band: { "type": "peak", "hz": 1000, "q": 1.4, "gainDB": -3 }.
public struct EQBand: Codable, Equatable {
    public var type: EQType
    public var hz: Double
    public var q: Double?
    public var gainDB: Double

    public init(_ type: EQType, hz: Double, q: Double? = nil, gainDB: Double = 0) {
        self.type = type; self.hz = hz; self.q = q; self.gainDB = gainDB
    }

    enum CodingKeys: String, CodingKey { case type, hz, q, gainDB }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(EQType.self, forKey: .type)
        hz = try c.decode(Double.self, forKey: .hz)
        q = try c.decodeIfPresent(Double.self, forKey: .q)
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
    }
}

/// A speaker: the output it plays on, where it is, and its system-layer processing (alignment
/// delay, EQ, trim, polarity, limiter, mute), which cues and snapshots will never touch.
public struct SpeakerConfig: Codable, Equatable {
    /// Engine output, from 1.
    public var output: Int
    public var name: String?
    public var position: Position
    public var delayMS: Double
    public var trimDB: Double
    /// Flips polarity.
    public var invert: Bool
    public var mute: Bool
    /// Up to 8 bands.
    public var eq: [EQBand]
    /// The limiter's threshold in dB re full scale (peak); none means no limiter.
    public var limiterDB: Double?
    public var limiterReleaseMS: Double

    public init(output: Int, name: String? = nil, position: Position, delayMS: Double = 0, trimDB: Double = 0,
                invert: Bool = false, mute: Bool = false, eq: [EQBand] = [], limiterDB: Double? = nil,
                limiterReleaseMS: Double = 200) {
        self.output = output; self.name = name; self.position = position; self.delayMS = delayMS
        self.trimDB = trimDB; self.invert = invert; self.mute = mute; self.eq = eq
        self.limiterDB = limiterDB; self.limiterReleaseMS = limiterReleaseMS
    }

    enum CodingKeys: String, CodingKey { case output, name, position, delayMS, trimDB, invert, mute, eq, limiterDB, limiterReleaseMS }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        output = try c.decode(Int.self, forKey: .output)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        position = try c.decode(Position.self, forKey: .position)
        delayMS = try c.decodeIfPresent(Double.self, forKey: .delayMS) ?? 0
        trimDB = try c.decodeIfPresent(Double.self, forKey: .trimDB) ?? 0
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        mute = try c.decodeIfPresent(Bool.self, forKey: .mute) ?? false
        eq = try c.decodeIfPresent([EQBand].self, forKey: .eq) ?? []
        limiterDB = try c.decodeIfPresent(Double.self, forKey: .limiterDB)
        limiterReleaseMS = try c.decodeIfPresent(Double.self, forKey: .limiterReleaseMS) ?? 200
    }

    /// "L (output 3)" or "output 3".
    public var label: String { name.map { "\($0) (output \(output))" } ?? "output \(output)" }
}

public enum Renderer: String, Codable, Equatable {
    /// Delay-based reinforcement (TiMax and Soundscape style): the main one for live.
    case delay
    /// Vector-base amplitude panning, for overheads, domes, rings and lines.
    case vbap
    /// Distance-based amplitude panning, for irregular layouts with no sweet spot.
    case dbap
}

/// A speaker group and the renderer that feeds it. Only the keys for its renderer are used.
public struct GroupConfig: Codable, Equatable {
    public var name: String
    public var renderer: Renderer
    /// The group's speakers by output number: "1-8", "1-8, 12, 20-24".
    public var speakers: String
    public var gainDB: Double
    /// Per-speaker level in the group, by output number: { "5": -6 }.
    public var weightsDB: [String: Double]

    // Delay
    /// tau_0: how long after the natural sound the speakers arrive.
    public var precedenceMS: Double
    /// alpha for Delay and VBAP: 1 gives 6 dB less per doubling of distance, 0 none.
    public var rolloff: Double
    /// d_r in metres. None: Delay uses the nearest speaker's distance (at least 1 m), VBAP the
    /// speakers' mean distance from the reference.
    public var referenceDistance: Double?
    /// d_0 in metres (Delay). None: the nearest speaker's distance, so it plays after the precedence only.
    public var distanceOffset: Double?

    // VBAP
    /// The listening point directions are taken from. None: the speakers' centre in plan, 1.2 m up.
    public var reference: Position?
    /// 2 or 3; none chooses 2D when the speakers are all at about the same elevation.
    public var dimensions: Int?

    // DBAP
    /// r_s in metres: keeps one speaker from taking everything when a source sits on it.
    public var blur: Double
    /// R: dB per doubling of distance.
    public var rolloffDB: Double

    public init(name: String, renderer: Renderer, speakers: String, gainDB: Double = 0, weightsDB: [String: Double] = [:],
                precedenceMS: Double = 10, rolloff: Double = 1, referenceDistance: Double? = nil,
                distanceOffset: Double? = nil, reference: Position? = nil, dimensions: Int? = nil,
                blur: Double = 0.5, rolloffDB: Double = 6) {
        self.name = name; self.renderer = renderer; self.speakers = speakers; self.gainDB = gainDB
        self.weightsDB = weightsDB; self.precedenceMS = precedenceMS; self.rolloff = rolloff
        self.referenceDistance = referenceDistance; self.distanceOffset = distanceOffset
        self.reference = reference; self.dimensions = dimensions; self.blur = blur; self.rolloffDB = rolloffDB
    }

    enum CodingKeys: String, CodingKey {
        case name, renderer, speakers, gainDB, weightsDB, precedenceMS, rolloff, referenceDistance, distanceOffset,
             reference, dimensions, blur, rolloffDB
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GroupConfig(name: "", renderer: .delay, speakers: "")
        name = try c.decode(String.self, forKey: .name)
        renderer = try c.decode(Renderer.self, forKey: .renderer)
        if let n = try? c.decode(Int.self, forKey: .speakers) { speakers = String(n) } else {
            speakers = try c.decode(String.self, forKey: .speakers)
        }
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? d.gainDB
        weightsDB = try c.decodeIfPresent([String: Double].self, forKey: .weightsDB) ?? d.weightsDB
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

/// A source: an engine input placed in the venue and sent to speaker groups.
public struct SourceConfig: Codable, Equatable {
    /// Engine input, from 1.
    public var input: Int
    public var name: String?
    public var position: Position
    public var gainDB: Double
    public var mute: Bool
    /// Spread in degrees (VBAP groups).
    public var width: Double
    /// Send level in dB per group name. None sends to every group at 0 dB.
    public var groups: [String: Double]?
    /// Send to the LFE outputs in dB; none sends nothing.
    public var lfeDB: Double?

    public init(input: Int, name: String? = nil, position: Position, gainDB: Double = 0, mute: Bool = false,
                width: Double = 0, groups: [String: Double]? = nil, lfeDB: Double? = nil) {
        self.input = input; self.name = name; self.position = position; self.gainDB = gainDB; self.mute = mute
        self.width = width; self.groups = groups; self.lfeDB = lfeDB
    }

    enum CodingKeys: String, CodingKey { case input, name, position, gainDB, mute, width, groups, lfeDB }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decode(Int.self, forKey: .input)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        position = try c.decode(Position.self, forKey: .position)
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        mute = try c.decodeIfPresent(Bool.self, forKey: .mute) ?? false
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0
        // Either { "Main": 0, "Overheads": -6 } or a plain list of names at 0 dB.
        if let names = try? c.decodeIfPresent([String].self, forKey: .groups) {
            groups = Dictionary(names.map { ($0, 0.0) }, uniquingKeysWith: { a, _ in a })
        } else {
            groups = try c.decodeIfPresent([String: Double].self, forKey: .groups)
        }
        lfeDB = try c.decodeIfPresent(Double.self, forKey: .lfeDB)
    }

    /// "Vox (input 1)" or "input 1".
    public var label: String { name.map { "\($0) (input \(input))" } ?? "input \(input)" }
}

/// Moves one source by itself, to hear the renderers' glides and crossfades with nothing but the
/// test signal: round a circle, or back and forth along a line.
public struct TestMotion: Codable, Equatable {
    public enum Shape: String, Codable { case circle, line }

    /// The source's input number.
    public var source: Int
    public var shape: Shape
    /// Circle: its centre and radius.
    public var center: Position
    public var radius: Double
    /// Line: its two ends.
    public var from: Position?
    public var to: Position?
    /// One full turn, or there and back.
    public var seconds: Double

    public init(source: Int, shape: Shape = .circle, center: Position = Position(0, 4, 1.6), radius: Double = 4,
                from: Position? = nil, to: Position? = nil, seconds: Double = 20) {
        self.source = source; self.shape = shape; self.center = center; self.radius = radius
        self.from = from; self.to = to; self.seconds = seconds
    }

    enum CodingKeys: String, CodingKey { case source, shape, center, radius, from, to, seconds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TestMotion(source: 1)
        source = try c.decode(Int.self, forKey: .source)
        shape = try c.decodeIfPresent(Shape.self, forKey: .shape) ?? d.shape
        center = try c.decodeIfPresent(Position.self, forKey: .center) ?? d.center
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? d.radius
        from = try c.decodeIfPresent(Position.self, forKey: .from)
        to = try c.decodeIfPresent(Position.self, forKey: .to)
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? d.seconds
    }

    /// Where the source is `t` seconds after the motion started.
    public func position(at t: Double) -> Position {
        let phase = (t / max(seconds, 0.1)).truncatingRemainder(dividingBy: 1)
        switch shape {
        case .circle:
            let a = 2 * Double.pi * phase
            return Position(center.x + radius * sin(a), center.y - radius * cos(a), center.z)
        case .line:
            let a = from ?? center, b = to ?? center
            let s = phase < 0.5 ? phase * 2 : 2 - phase * 2
            return Position(a.x + (b.x - a.x) * s, a.y + (b.y - a.y) * s, a.z + (b.z - a.z) * s)
        }
    }
}

extension Routing {
    /// Parses a channel list such as "1-8, 12, 20-24" into channel numbers from 1, in order.
    public static func channelList(_ text: String, limit: Int, side: String) throws -> [Int] {
        var result: [Int] = []
        for part in text.split(separator: ",") {
            result += try channels(String(part), limit: limit, side: side)
        }
        guard !result.isEmpty else { throw ConfigError("no \(side)s in '\(text)'") }
        return result
    }
}

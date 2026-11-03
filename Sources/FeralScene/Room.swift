import FeralCore
import Foundation

// The spatial reverb's rooms. A room is a shoebox around the listener: its walls give every source
// that plays into it early reflections (image sources, panned over the room's speakers from the
// listener), and its late tail is a feedback delay network in the render core, spread decorrelated
// over the same speakers. Rooms live in show.json; sources pick one in their `reverb`.

/// A room of the reverb.
public struct Room: Codable, Equatable, Identifiable {
    /// The most rooms a show can have (the render core runs up to this many).
    public static let maxRooms = Int(FERAL_MAX_ROOMS)

    public var id: UUID
    public var number: Int
    public var name: String
    /// Mutes the whole room: its tail and every source's reflections in it.
    public var mute: Bool
    /// The shoebox in metres: width (x, across the stage), depth (y) and height (z).
    public var width: Double
    public var depth: Double
    public var height: Double
    /// The middle of its floor; none puts it under the listener (floor at 0).
    public var centre: Position?
    /// The decay time (RT60) in seconds in the mids (0.1 to 30).
    public var decayS: Double
    /// The low and high decays as multiples of the mid one (below 177 Hz and above 5.7 kHz): above 1
    /// is warmer or brighter, below 1 thinner or darker.
    public var lowDecay: Double
    public var highDecay: Double
    /// Extra time before the tail starts, in ms (0 to 500).
    public var predelayMS: Double
    /// The tail's level in dB.
    public var levelDB: Double
    /// The early reflections' level in dB.
    public var earlyDB: Double
    /// How much the walls absorb, 0 (hard, bright reflections) to 1 (soft, dull and quiet ones).
    public var absorption: Double
    /// How smeared the tail starts, 0 to 1.
    public var diffusion: Double
    /// How much the tail's lines wander, 0 to 1 (smooths its colour; 0 can ring metallic).
    public var modulation: Double
    /// Plays on `speakers` only; otherwise on every speaker but the LFE ones.
    public var useSpeakerSubset: Bool
    public var speakers: [UUID]
    /// "#RRGGBB" for the app; none picks one from the number.
    public var colour: String?

    public init(id: UUID = UUID(), number: Int, name: String, mute: Bool = false, width: Double = 20, depth: Double = 25,
                height: Double = 10, centre: Position? = nil, decayS: Double = 2, lowDecay: Double = 1.2,
                highDecay: Double = 0.6, predelayMS: Double = 0, levelDB: Double = -6, earlyDB: Double = 0,
                absorption: Double = 0.3, diffusion: Double = 0.7, modulation: Double = 0.5, useSpeakerSubset: Bool = false,
                speakers: [UUID] = [], colour: String? = nil) {
        self.id = id; self.number = number; self.name = name; self.mute = mute
        self.width = width; self.depth = depth; self.height = height; self.centre = centre
        self.decayS = decayS; self.lowDecay = lowDecay; self.highDecay = highDecay; self.predelayMS = predelayMS
        self.levelDB = levelDB; self.earlyDB = earlyDB; self.absorption = absorption; self.diffusion = diffusion
        self.modulation = modulation; self.useSpeakerSubset = useSpeakerSubset; self.speakers = speakers; self.colour = colour
    }

    enum CodingKeys: String, CodingKey {
        case id, number, name, mute, width, depth, height, centre, decayS, lowDecay, highDecay, predelayMS, levelDB, earlyDB,
             absorption, diffusion, modulation, useSpeakerSubset, speakers, colour
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Room(number: 1, name: "Room")
        id = try c.decode(UUID.self, forKey: .id)
        number = try c.decodeIfPresent(Int.self, forKey: .number) ?? 1
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Room \(number)"
        mute = try c.decodeIfPresent(Bool.self, forKey: .mute) ?? false
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? d.width
        depth = try c.decodeIfPresent(Double.self, forKey: .depth) ?? d.depth
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? d.height
        centre = try c.decodeIfPresent(Position.self, forKey: .centre)
        decayS = try c.decodeIfPresent(Double.self, forKey: .decayS) ?? d.decayS
        lowDecay = try c.decodeIfPresent(Double.self, forKey: .lowDecay) ?? d.lowDecay
        highDecay = try c.decodeIfPresent(Double.self, forKey: .highDecay) ?? d.highDecay
        predelayMS = try c.decodeIfPresent(Double.self, forKey: .predelayMS) ?? d.predelayMS
        levelDB = try c.decodeIfPresent(Double.self, forKey: .levelDB) ?? d.levelDB
        earlyDB = try c.decodeIfPresent(Double.self, forKey: .earlyDB) ?? d.earlyDB
        absorption = try c.decodeIfPresent(Double.self, forKey: .absorption) ?? d.absorption
        diffusion = try c.decodeIfPresent(Double.self, forKey: .diffusion) ?? d.diffusion
        modulation = try c.decodeIfPresent(Double.self, forKey: .modulation) ?? d.modulation
        useSpeakerSubset = try c.decodeIfPresent(Bool.self, forKey: .useSpeakerSubset) ?? false
        speakers = try c.decodeIfPresent([UUID].self, forKey: .speakers) ?? []
        colour = try c.decodeIfPresent(String.self, forKey: .colour)
    }

    /// "1 Hall".
    public var label: String { "\(number) \(name)" }

    /// Ready-made rooms, from a small studio to a cathedral.
    public enum Preset: String, CaseIterable, Codable {
        case studio, club, theatre, hall, arena, cathedral

        public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

        /// Size (width, depth, height), mid decay, low and high multiples, absorption, pre-delay.
        var values: (Double, Double, Double, Double, Double, Double, Double, Double) {
            switch self {
            case .studio: return (6, 8, 3.5, 0.4, 1.1, 0.7, 0.5, 0)
            case .club: return (15, 20, 6, 1.0, 1.3, 0.6, 0.45, 0)
            case .theatre: return (20, 25, 12, 1.4, 1.2, 0.6, 0.35, 5)
            case .hall: return (28, 40, 16, 2.2, 1.2, 0.6, 0.25, 15)
            case .arena: return (70, 100, 30, 3.5, 1.4, 0.5, 0.3, 25)
            case .cathedral: return (30, 80, 30, 7.5, 1.3, 0.5, 0.1, 30)
            }
        }
    }

    /// This room with a preset's size, decay, absorption and pre-delay (the rest is kept).
    public func with(_ preset: Preset) -> Room {
        var r = self
        let v = preset.values
        r.width = v.0; r.depth = v.1; r.height = v.2; r.decayS = v.3; r.lowDecay = v.4; r.highDecay = v.5
        r.absorption = v.6; r.predelayMS = v.7
        return r
    }

    func check() throws {
        func within(_ v: Double, _ r: ClosedRange<Double>, _ what: String) throws {
            guard v.isFinite, r.contains(v) else { throw ConfigError("room \(label): \(what) must be from \(r.lowerBound) to \(r.upperBound)") }
        }
        try within(width, 1...500, "width (m)")
        try within(depth, 1...500, "depth (m)")
        try within(height, 1...200, "height (m)")
        try within(decayS, 0.1...30, "decay (s)")
        try within(lowDecay, 0.1...4, "the low decay multiple")
        try within(highDecay, 0.1...4, "the high decay multiple")
        try within(predelayMS, 0...500, "pre-delay (ms)")
        try within(levelDB, -90...24, "level (dB)")
        try within(earlyDB, -90...24, "the early reflections' level (dB)")
        try within(absorption, 0...1, "absorption")
        try within(diffusion, 0...1, "diffusion")
        try within(modulation, 0...1, "modulation")
        if let c = centre { guard c.x.isFinite, c.y.isFinite, c.z.isFinite else { throw ConfigError("room \(label): centre must be finite") } }
    }
}

/// A source's reverb: the room it plays into, its send to the room's tail, and its early reflections.
public struct SourceReverb: Codable, Equatable {
    /// None: no reverb.
    public var room: UUID?
    /// The send to the room's tail, in dB.
    public var sendDB: Double
    /// Its early reflections in the room, and their level in dB.
    public var early: Bool
    public var earlyDB: Double

    public init(room: UUID?, sendDB: Double = 0, early: Bool = true, earlyDB: Double = 0) {
        self.room = room; self.sendDB = sendDB; self.early = early; self.earlyDB = earlyDB
    }

    public static let off = SourceReverb(room: nil)

    enum CodingKeys: String, CodingKey { case room, sendDB, early, earlyDB }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        room = try c.decodeIfPresent(UUID.self, forKey: .room)
        sendDB = try c.decodeIfPresent(Double.self, forKey: .sendDB) ?? 0
        early = try c.decodeIfPresent(Bool.self, forKey: .early) ?? true
        earlyDB = try c.decodeIfPresent(Double.self, forKey: .earlyDB) ?? 0
    }

    func check(_ context: String) throws {
        guard sendDB.isFinite, sendDB <= 24 else { throw ConfigError("\(context): the reverb send must be 24 dB or below") }
        guard earlyDB.isFinite, earlyDB <= 24 else { throw ConfigError("\(context): the early reflections must be 24 dB or below") }
    }

    /// This reverb a fraction `t` (after the curve, below 1) of the way to `b`: levels move in dB (a
    /// room turning on fades up from -60 dB, one turning off fades down to it), and a change of room
    /// happens halfway.
    func fading(to b: SourceReverb, at t: Double) -> SourceReverb {
        let floor = SnapshotFade.floorDB
        func level(_ r: SourceReverb, _ v: Double) -> Double { r.room == nil ? floor : v }
        func earlyLevel(_ r: SourceReverb) -> Double { r.room == nil || !r.early ? floor : r.earlyDB }
        var v = t < 0.5 || b.room == nil ? self : b
        if v.room == nil { v.room = b.room }
        if room != nil && b.room != nil && room != b.room {
            // Into the new room from halfway: down to the floor, then up from it.
            let s = t < 0.5 ? 1 - 2 * t : 2 * t - 1
            let from = t < 0.5 ? self : b
            v.sendDB = floor + (from.sendDB - floor) * s
            v.earlyDB = floor + (earlyLevel(from) - floor) * s
            v.early = from.early
            return v
        }
        v.sendDB = level(self, sendDB) + (level(b, b.sendDB) - level(self, sendDB)) * t
        v.earlyDB = earlyLevel(self) + (earlyLevel(b) - earlyLevel(self)) * t
        v.early = early || b.early
        return v
    }
}

// MARK: - As the renderer takes them

/// A room as the renderer takes it: the box, the decay, and the speakers it plays on by output.
public struct RoomConfig: Equatable {
    public var name: String
    /// Muted rooms play nothing (and their tail is not run).
    public var on: Bool
    /// The box's corners.
    public var low: Position
    public var high: Position
    public var decayS: Double
    public var lowDecay: Double
    public var highDecay: Double
    public var predelayMS: Double
    public var levelDB: Double
    public var earlyDB: Double
    public var absorption: Double
    public var diffusion: Double
    public var modulation: Double
    /// Its speakers by output number ("1-8, 12"); empty plays nowhere.
    public var speakers: [Int]
    /// The listening point reflections are panned and timed from.
    public var listener: Position

    public init(name: String, on: Bool = true, low: Position, high: Position, decayS: Double = 2, lowDecay: Double = 1.2,
                highDecay: Double = 0.6, predelayMS: Double = 0, levelDB: Double = -6, earlyDB: Double = 0,
                absorption: Double = 0.3, diffusion: Double = 0.7, modulation: Double = 0.5, speakers: [Int], listener: Position) {
        self.name = name; self.on = on; self.low = low; self.high = high; self.decayS = decayS; self.lowDecay = lowDecay
        self.highDecay = highDecay; self.predelayMS = predelayMS; self.levelDB = levelDB; self.earlyDB = earlyDB
        self.absorption = absorption; self.diffusion = diffusion; self.modulation = modulation; self.speakers = speakers
        self.listener = listener
    }

    /// The mean free path's travel time, which sets the tail's line lengths: 4 V / S over c.
    public func meanFreeTime(speedOfSound c: Double) -> Double {
        let w = high.x - low.x, d = high.y - low.y, h = high.z - low.z
        let volume = w * d * h, surface = 2 * (w * d + w * h + d * h)
        return surface > 0 ? 4 * volume / surface / c : 0.02
    }

    /// The early reflections' wall filter: dull walls take the highs off.
    public func wallFilter(sampleRate: Double) -> [Biquad] {
        let soft = min(max(absorption, 0), 1)
        let hz = min(18_000, 2_500 + 15_500 * (1 - soft) * (1 - soft))
        return [Biquad(EQBand(.lowPass, hz: min(hz, 0.45 * sampleRate)), sampleRate: sampleRate),
                Biquad(EQBand(.highPass, hz: 40), sampleRate: sampleRate)]
    }
}

/// A source's reverb as the renderer takes it: the room by its index in EngineConfig.rooms, the
/// send's gain (with the source's level and its groups', but no distance modelling: a farther source
/// keeps its reverb, which is what makes it sound farther) and its reflections' level.
public struct SourceReverbConfig: Equatable {
    public var room: Int
    public var sendDB: Double
    /// None: no early reflections.
    public var earlyDB: Double?

    public init(room: Int, sendDB: Double, earlyDB: Double?) {
        self.room = room; self.sendDB = sendDB; self.earlyDB = earlyDB
    }
}

/// One early reflection: where its image source is, how long after the direct sound it arrives (s),
/// and its gain relative to the source's send.
public struct Reflection: Equatable {
    public var image: Position
    public var delay: Double
    public var gain: Double
    /// Walls it bounced off.
    public var order: Int
}

public enum ImageSources {
    /// The first and second order image sources of a source in a box, heard from a listener: the
    /// six first-order ones and the ten earliest second-order ones, earliest first. Delays are after
    /// the direct sound (at least `minimumDelay`, so a reflection never comes first); gains fall as
    /// 1/distance relative to the direct sound (taken as at least 1 m away) and by the walls'
    /// reflectance each bounce. A source or listener outside the box is moved onto its nearest wall.
    public static func reflections(source: Position, listener: Position, low: Position, high: Position,
                                   absorption: Double, speedOfSound c: Double, minimumDelay: Double = 0.001,
                                   count: Int = Int(FERAL_MAX_REFLECTIONS)) -> [Reflection] {
        func clamp(_ p: Position) -> Position {
            Position(min(max(p.x, low.x), high.x), min(max(p.y, low.y), high.y), min(max(p.z, low.z), high.z))
        }
        let s = clamp(source), l = clamp(listener)
        let lo = [low.x, low.y, low.z], hi = [high.x, high.y, high.z]
        func get(_ p: Position, _ a: Int) -> Double { a == 0 ? p.x : (a == 1 ? p.y : p.z) }
        func set(_ p: inout Position, _ a: Int, _ v: Double) { if a == 0 { p.x = v } else if a == 1 { p.y = v } else { p.z = v } }
        func mirror(_ p: Position, axis a: Int, high side: Bool) -> Position {
            var q = p
            let wall = side ? hi[a] : lo[a]
            set(&q, a, 2 * wall - get(p, a))
            return q
        }
        var first: [Position] = []
        for a in 0..<3 { for side in [false, true] { first.append(mirror(s, axis: a, high: side)) } }
        var second: [Position] = []
        // Two walls of different axes (an edge), and the same axis twice (opposite walls).
        for a in 0..<3 {
            for b in 0..<3 where b > a {
                for sa in [false, true] { for sb in [false, true] { second.append(mirror(mirror(s, axis: a, high: sa), axis: b, high: sb)) } }
            }
            second.append(mirror(mirror(s, axis: a, high: false), axis: a, high: true))
            second.append(mirror(mirror(s, axis: a, high: true), axis: a, high: false))
        }
        let direct = s.distance(to: l)
        let reflectance = (1 - min(max(absorption, 0), 0.999)).squareRoot()
        func make(_ p: Position, order: Int) -> Reflection {
            let d = max(p.distance(to: l), 1e-3)
            return Reflection(image: p, delay: max(minimumDelay, (d - direct) / c),
                              gain: min(1, max(direct, 1) / d) * pow(reflectance, Double(order)), order: order)
        }
        let firsts = first.map { make($0, order: 1) }
        let seconds = second.map { make($0, order: 2) }.sorted { $0.delay < $1.delay }
        return Array((firsts + seconds.prefix(max(0, count - firsts.count))).sorted { $0.delay < $1.delay }.prefix(count))
    }

    /// Whether line `line` of a room's tail plays inverted on the room's `speaker`-th speaker: the
    /// first 16 speakers take the rows of a 16 by 16 Hadamard matrix (so their feeds are uncorrelated),
    /// later ones the same rows with a different sign pattern each.
    public static func tailSign(speaker: Int, line: Int) -> Bool {
        let row = speaker % Int(FERAL_ROOM_LINES), round = speaker / Int(FERAL_ROOM_LINES)
        var parity = (row & line).nonzeroBitCount & 1 == 1
        if round > 0 {
            var h = UInt32(truncatingIfNeeded: round) &* 2_654_435_761 ^ UInt32(truncatingIfNeeded: line) &* 40_503
            h ^= h >> 13
            h = h &* 0x5bd1_e995
            if (h >> 7) & 1 == 1 { parity.toggle() }
        }
        return parity
    }
}

import FeralCore
import Foundation

/// A source's channel EQ, as on a console: a high-pass filter, a low shelf, three peak bands (low
/// mid, mid, high mid) and a high shelf. Off passes the input through untouched.
public struct SourceEQ: Codable, Equatable {
    public var on: Bool
    /// The high-pass filter's corner; none is off.
    public var highPassHz: Double?
    public var lowHz: Double
    public var lowDB: Double
    public var lowMidHz: Double
    public var lowMidDB: Double
    public var lowMidQ: Double
    public var midHz: Double
    public var midDB: Double
    public var midQ: Double
    public var highMidHz: Double
    public var highMidDB: Double
    public var highMidQ: Double
    public var highHz: Double
    public var highDB: Double

    public init(on: Bool = false, highPassHz: Double? = nil, lowHz: Double = 100, lowDB: Double = 0,
                lowMidHz: Double = 250, lowMidDB: Double = 0, lowMidQ: Double = 1,
                midHz: Double = 1000, midDB: Double = 0, midQ: Double = 1,
                highMidHz: Double = 4000, highMidDB: Double = 0, highMidQ: Double = 1,
                highHz: Double = 8000, highDB: Double = 0) {
        self.on = on; self.highPassHz = highPassHz; self.lowHz = lowHz; self.lowDB = lowDB
        self.lowMidHz = lowMidHz; self.lowMidDB = lowMidDB; self.lowMidQ = lowMidQ
        self.midHz = midHz; self.midDB = midDB; self.midQ = midQ
        self.highMidHz = highMidHz; self.highMidDB = highMidDB; self.highMidQ = highMidQ
        self.highHz = highHz; self.highDB = highDB
    }

    public static let flat = SourceEQ()

    enum CodingKeys: String, CodingKey {
        case on, highPassHz, lowHz, lowDB, lowMidHz, lowMidDB, lowMidQ, midHz, midDB, midQ, highMidHz, highMidDB, highMidQ, highHz, highDB
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SourceEQ()
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? d.on
        highPassHz = try c.decodeIfPresent(Double.self, forKey: .highPassHz)
        lowHz = try c.decodeIfPresent(Double.self, forKey: .lowHz) ?? d.lowHz
        lowDB = try c.decodeIfPresent(Double.self, forKey: .lowDB) ?? d.lowDB
        lowMidHz = try c.decodeIfPresent(Double.self, forKey: .lowMidHz) ?? d.lowMidHz
        lowMidDB = try c.decodeIfPresent(Double.self, forKey: .lowMidDB) ?? d.lowMidDB
        lowMidQ = try c.decodeIfPresent(Double.self, forKey: .lowMidQ) ?? d.lowMidQ
        highMidHz = try c.decodeIfPresent(Double.self, forKey: .highMidHz) ?? d.highMidHz
        highMidDB = try c.decodeIfPresent(Double.self, forKey: .highMidDB) ?? d.highMidDB
        highMidQ = try c.decodeIfPresent(Double.self, forKey: .highMidQ) ?? d.highMidQ
        midHz = try c.decodeIfPresent(Double.self, forKey: .midHz) ?? d.midHz
        midDB = try c.decodeIfPresent(Double.self, forKey: .midDB) ?? d.midDB
        midQ = try c.decodeIfPresent(Double.self, forKey: .midQ) ?? d.midQ
        highHz = try c.decodeIfPresent(Double.self, forKey: .highHz) ?? d.highHz
        highDB = try c.decodeIfPresent(Double.self, forKey: .highDB) ?? d.highDB
    }

    /// The bands that change the sound: none when off; a band at 0 dB is left out.
    public var bands: [EQBand] {
        guard on else { return [] }
        var out: [EQBand] = []
        if let hp = highPassHz { out.append(EQBand(.highPass, hz: hp)) }
        if lowDB != 0 { out.append(EQBand(.lowShelf, hz: lowHz, gainDB: lowDB)) }
        if lowMidDB != 0 { out.append(EQBand(.peak, hz: lowMidHz, q: lowMidQ, gainDB: lowMidDB)) }
        if midDB != 0 { out.append(EQBand(.peak, hz: midHz, q: midQ, gainDB: midDB)) }
        if highMidDB != 0 { out.append(EQBand(.peak, hz: highMidHz, q: highMidQ, gainDB: highMidDB)) }
        if highDB != 0 { out.append(EQBand(.highShelf, hz: highHz, gainDB: highDB)) }
        return out
    }

    /// Frequencies 20 Hz to 20 kHz, gains ±24 dB, Q 0.1 to 10.
    func check(_ who: String) throws {
        let freqs = [lowHz, lowMidHz, midHz, highMidHz, highHz] + (highPassHz.map { [$0] } ?? [])
        guard freqs.allSatisfy({ $0.isFinite && (20...20_000).contains($0) }) else {
            throw ConfigError("\(who): EQ frequencies must be from 20 Hz to 20 kHz")
        }
        guard [lowDB, lowMidDB, midDB, highMidDB, highDB].allSatisfy({ $0.isFinite && abs($0) <= 24 }) else {
            throw ConfigError("\(who): EQ gains must be within ±24 dB")
        }
        guard [lowMidQ, midQ, highMidQ].allSatisfy({ $0.isFinite && (0.1...10).contains($0) }) else { throw ConfigError("\(who): EQ Q must be from 0.1 to 10") }
    }
}

/// A source's compressor: above the threshold, level rises 1 dB for every `ratio` dB in. Off passes
/// the input through untouched (makeup included).
public struct Compressor: Codable, Equatable {
    public var on: Bool
    public var thresholdDB: Double
    public var ratio: Double
    public var attackMS: Double
    public var releaseMS: Double
    public var makeupDB: Double

    public init(on: Bool = false, thresholdDB: Double = -20, ratio: Double = 3, attackMS: Double = 10,
                releaseMS: Double = 150, makeupDB: Double = 0) {
        self.on = on; self.thresholdDB = thresholdDB; self.ratio = ratio; self.attackMS = attackMS
        self.releaseMS = releaseMS; self.makeupDB = makeupDB
    }

    public static let off = Compressor()

    enum CodingKeys: String, CodingKey { case on, thresholdDB, ratio, attackMS, releaseMS, makeupDB }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Compressor()
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? d.on
        thresholdDB = try c.decodeIfPresent(Double.self, forKey: .thresholdDB) ?? d.thresholdDB
        ratio = try c.decodeIfPresent(Double.self, forKey: .ratio) ?? d.ratio
        attackMS = try c.decodeIfPresent(Double.self, forKey: .attackMS) ?? d.attackMS
        releaseMS = try c.decodeIfPresent(Double.self, forKey: .releaseMS) ?? d.releaseMS
        makeupDB = try c.decodeIfPresent(Double.self, forKey: .makeupDB) ?? d.makeupDB
    }

    /// Threshold -60 to 0 dB, ratio 1 to 20, attack 0.1 to 200 ms, release 5 to 2000 ms, makeup 0 to 24 dB.
    func check(_ who: String) throws {
        func within(_ v: Double, _ r: ClosedRange<Double>) -> Bool { v.isFinite && r.contains(v) }
        guard within(thresholdDB, -60...0) else { throw ConfigError("\(who): compressor threshold must be from -60 to 0 dB") }
        guard within(ratio, 1...20) else { throw ConfigError("\(who): compressor ratio must be from 1 to 20") }
        guard within(attackMS, 0.1...200) else { throw ConfigError("\(who): compressor attack must be from 0.1 to 200 ms") }
        guard within(releaseMS, 5...2000) else { throw ConfigError("\(who): compressor release must be from 5 to 2000 ms") }
        guard within(makeupDB, 0...24) else { throw ConfigError("\(who): compressor makeup must be from 0 to 24 dB") }
    }
}

/// One input's processing in the render core (see feral_input_params): EQ, then a compressor.
public struct InputParams: Equatable {
    public static let bands = Int(FERAL_INPUT_EQ_BANDS)

    /// Up to `bands` sections; missing ones pass through.
    public var eq: [Biquad] = []
    /// Linear; 0 is off.
    public var threshold: Float = 0
    public var ratio: Float = 1
    /// Per-sample follower factors.
    public var attack: Float = 0
    public var release: Float = 0
    public var makeup: Float = 1
    /// The other input (from 0) whose level also drives this compressor; none is -1.
    public var link: Int = -1

    public init() {}

    /// A source's EQ and compressor at a sample rate; `link` is the stereo partner's input from 0.
    public init(eq: SourceEQ?, compressor: Compressor?, link: Int?, sampleRate: Double) {
        self.eq = (eq?.bands ?? []).prefix(Self.bands).map { Biquad($0, sampleRate: sampleRate) }
        if let c = compressor, c.on, c.ratio > 1 {
            threshold = Float(pow(10, c.thresholdDB / 20))
            ratio = Float(c.ratio)
            attack = Float(exp(-1 / (max(c.attackMS, 0.01) / 1000 * sampleRate)))
            release = Float(exp(-1 / (max(c.releaseMS, 0.01) / 1000 * sampleRate)))
            makeup = Float(pow(10, c.makeupDB / 20))
        }
        self.link = link ?? -1
    }

    public var isPlain: Bool { eq.allSatisfy { $0 == .flat } && threshold == 0 && makeup == 1 }

    var cValue: feral_input_params {
        var p = feral_input_defaults()
        withUnsafeMutableBytes(of: &p.eq) { raw in
            let bands = raw.bindMemory(to: feral_biquad.self)
            for (i, b) in eq.prefix(InputParams.bands).enumerated() {
                bands[i] = feral_biquad(b0: b.b0, b1: b.b1, b2: b.b2, a1: b.a1, a2: b.a2)
            }
        }
        p.comp_threshold = threshold
        p.comp_ratio = ratio
        p.comp_attack = attack
        p.comp_release = release
        p.comp_makeup = makeup
        p.link = Int32(link)
        return p
    }
}

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
    public func check(_ who: String) throws {
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

/// One band of a multiband compressor.
public struct CompressorBand: Codable, Equatable {
    public var thresholdDB: Double
    public var ratio: Double
    public var attackMS: Double
    public var releaseMS: Double
    /// The band's level after its compressor.
    public var gainDB: Double

    public init(thresholdDB: Double = -20, ratio: Double = 3, attackMS: Double = 10, releaseMS: Double = 150, gainDB: Double = 0) {
        self.thresholdDB = thresholdDB; self.ratio = ratio; self.attackMS = attackMS; self.releaseMS = releaseMS; self.gainDB = gainDB
    }

    enum CodingKeys: String, CodingKey { case thresholdDB, ratio, attackMS, releaseMS, gainDB }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CompressorBand()
        thresholdDB = try c.decodeIfPresent(Double.self, forKey: .thresholdDB) ?? d.thresholdDB
        ratio = try c.decodeIfPresent(Double.self, forKey: .ratio) ?? d.ratio
        attackMS = try c.decodeIfPresent(Double.self, forKey: .attackMS) ?? d.attackMS
        releaseMS = try c.decodeIfPresent(Double.self, forKey: .releaseMS) ?? d.releaseMS
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? d.gainDB
    }
}

/// A source's compressor: above the threshold, level rises 1 dB for every `ratio` dB in. Multiband
/// splits the source at two crossovers (Linkwitz-Riley, adding back up flat) into low, mid and high,
/// each with its own compressor and gain. Off passes the input through untouched (makeup included).
public struct Compressor: Codable, Equatable {
    public static let bandCount = 3

    public var on: Bool
    public var thresholdDB: Double
    public var ratio: Double
    public var attackMS: Double
    public var releaseMS: Double
    public var makeupDB: Double
    public var multiband: Bool
    public var crossoverLowHz: Double
    public var crossoverHighHz: Double
    /// Low, mid and high.
    public var bands: [CompressorBand]

    public init(on: Bool = false, thresholdDB: Double = -20, ratio: Double = 3, attackMS: Double = 10,
                releaseMS: Double = 150, makeupDB: Double = 0, multiband: Bool = false, crossoverLowHz: Double = 200,
                crossoverHighHz: Double = 3000, bands: [CompressorBand]? = nil) {
        self.on = on; self.thresholdDB = thresholdDB; self.ratio = ratio; self.attackMS = attackMS
        self.releaseMS = releaseMS; self.makeupDB = makeupDB; self.multiband = multiband
        self.crossoverLowHz = crossoverLowHz; self.crossoverHighHz = crossoverHighHz
        self.bands = bands ?? Self.defaultBands
    }

    /// Slower on the low band, faster on the high.
    public static let defaultBands = [CompressorBand(attackMS: 30, releaseMS: 250), CompressorBand(attackMS: 10, releaseMS: 150),
                                      CompressorBand(attackMS: 3, releaseMS: 80)]

    public static let off = Compressor()

    enum CodingKeys: String, CodingKey {
        case on, thresholdDB, ratio, attackMS, releaseMS, makeupDB, multiband, crossoverLowHz, crossoverHighHz, bands
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Compressor()
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? d.on
        thresholdDB = try c.decodeIfPresent(Double.self, forKey: .thresholdDB) ?? d.thresholdDB
        ratio = try c.decodeIfPresent(Double.self, forKey: .ratio) ?? d.ratio
        attackMS = try c.decodeIfPresent(Double.self, forKey: .attackMS) ?? d.attackMS
        releaseMS = try c.decodeIfPresent(Double.self, forKey: .releaseMS) ?? d.releaseMS
        makeupDB = try c.decodeIfPresent(Double.self, forKey: .makeupDB) ?? d.makeupDB
        multiband = try c.decodeIfPresent(Bool.self, forKey: .multiband) ?? d.multiband
        crossoverLowHz = try c.decodeIfPresent(Double.self, forKey: .crossoverLowHz) ?? d.crossoverLowHz
        crossoverHighHz = try c.decodeIfPresent(Double.self, forKey: .crossoverHighHz) ?? d.crossoverHighHz
        bands = try c.decodeIfPresent([CompressorBand].self, forKey: .bands) ?? d.bands
    }

    /// Threshold -60 to 0 dB, ratio 1 to 20, attack 0.1 to 200 ms, release 5 to 2000 ms, makeup 0 to
    /// 24 dB; three bands with band gains within ±24 dB, crossovers 40 Hz to 16 kHz with the upper at
    /// least an octave above the lower.
    public func check(_ who: String) throws {
        func within(_ v: Double, _ r: ClosedRange<Double>) -> Bool { v.isFinite && r.contains(v) }
        func dynamics(_ threshold: Double, _ ratio: Double, _ attack: Double, _ release: Double, _ what: String) throws {
            guard within(threshold, -60...0) else { throw ConfigError("\(who): \(what)threshold must be from -60 to 0 dB") }
            guard within(ratio, 1...20) else { throw ConfigError("\(who): \(what)ratio must be from 1 to 20") }
            guard within(attack, 0.1...200) else { throw ConfigError("\(who): \(what)attack must be from 0.1 to 200 ms") }
            guard within(release, 5...2000) else { throw ConfigError("\(who): \(what)release must be from 5 to 2000 ms") }
        }
        try dynamics(thresholdDB, ratio, attackMS, releaseMS, "compressor ")
        guard within(makeupDB, 0...24) else { throw ConfigError("\(who): compressor makeup must be from 0 to 24 dB") }
        guard bands.count == Self.bandCount else { throw ConfigError("\(who): a multiband compressor has \(Self.bandCount) bands") }
        for (i, b) in bands.enumerated() {
            let name = ["low", "mid", "high"][i]
            try dynamics(b.thresholdDB, b.ratio, b.attackMS, b.releaseMS, "\(name) band ")
            guard within(b.gainDB, -24...24) else { throw ConfigError("\(who): \(name) band gain must be within ±24 dB") }
        }
        guard within(crossoverLowHz, 40...16_000), within(crossoverHighHz, 40...16_000), crossoverHighHz >= 2 * crossoverLowHz else {
            throw ConfigError("\(who): crossovers must be from 40 Hz to 16 kHz, the upper at least an octave above the lower")
        }
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
    /// Multiband: the crossover's sections (see FERAL_CROSSOVER_SECTIONS) and each band's compressor.
    public var multiband = false
    public var crossover: [Biquad] = []
    public var bands: [Band] = []

    /// One multiband band: linear threshold (0 off), ratio, per-sample follower factors, linear gain.
    public struct Band: Equatable {
        public var threshold: Float, ratio: Float, attack: Float, release: Float, gain: Float
    }

    public init() {}

    static func follower(_ ms: Double, _ sampleRate: Double) -> Float { Float(exp(-1 / (max(ms, 0.01) / 1000 * sampleRate))) }

    /// A source's EQ and compressor at a sample rate; `link` is the stereo partner's input from 0.
    public init(eq: SourceEQ?, compressor: Compressor?, link: Int?, sampleRate: Double) {
        self.eq = (eq?.bands ?? []).prefix(Self.bands).map { Biquad($0, sampleRate: sampleRate) }
        if let c = compressor, c.on, c.multiband, c.bands.count == Compressor.bandCount {
            multiband = true
            func section(_ type: EQType, _ hz: Double) -> Biquad { Biquad(EQBand(type, hz: hz), sampleRate: sampleRate) }
            let lp1 = section(.lowPass, c.crossoverLowHz), hp1 = section(.highPass, c.crossoverLowHz)
            let lp2 = section(.lowPass, c.crossoverHighHz), hp2 = section(.highPass, c.crossoverHighHz)
            crossover = [lp1, lp1, section(.allPass, c.crossoverHighHz), hp1, hp1, lp2, lp2, hp2, hp2]
            bands = c.bands.map { b in
                Band(threshold: b.ratio > 1 ? Float(pow(10, b.thresholdDB / 20)) : 0, ratio: Float(b.ratio),
                     attack: Self.follower(b.attackMS, sampleRate), release: Self.follower(b.releaseMS, sampleRate),
                     gain: Float(pow(10, b.gainDB / 20)))
            }
            makeup = Float(pow(10, c.makeupDB / 20))
        } else if let c = compressor, c.on, c.ratio > 1 {
            threshold = Float(pow(10, c.thresholdDB / 20))
            ratio = Float(c.ratio)
            attack = Self.follower(c.attackMS, sampleRate)
            release = Self.follower(c.releaseMS, sampleRate)
            makeup = Float(pow(10, c.makeupDB / 20))
        }
        self.link = link ?? -1
    }

    public var isPlain: Bool { eq.allSatisfy { $0 == .flat } && threshold == 0 && makeup == 1 && !multiband }

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
        p.multiband = multiband ? 1 : 0
        withUnsafeMutableBytes(of: &p.crossover) { raw in
            let sections = raw.bindMemory(to: feral_biquad.self)
            for (i, b) in crossover.prefix(Int(FERAL_CROSSOVER_SECTIONS)).enumerated() {
                sections[i] = feral_biquad(b0: b.b0, b1: b.b1, b2: b.b2, a1: b.a1, a2: b.a2)
            }
        }
        withUnsafeMutableBytes(of: &p.bands) { raw in
            let out = raw.bindMemory(to: feral_comp_band.self)
            for (i, b) in bands.prefix(Int(FERAL_COMP_BANDS)).enumerated() {
                out[i] = feral_comp_band(threshold: b.threshold, ratio: b.ratio, attack: b.attack, release: b.release, gain: b.gain)
            }
        }
        return p
    }
}

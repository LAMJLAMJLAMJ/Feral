import FeralCore
import Foundation

// The monitor (the Binaural output group): the speakers as a listener at the show's listening point
// would hear them, on two card outputs for headphones. It has its own two outputs, Binaural L and R,
// after Feral's speaker outputs, patched in the Patch window like them. Each speaker's feed is delayed and turned down for its distance (relative
// to the nearest speaker) and played through the head-related impulse responses (HRIRs) for its
// direction. What the monitor hears (the mix, the soloed sources, or PFL) is picked in the core.

/// engine.json's `monitor`: where the binaural monitor plays and how.
public struct MonitorSettings: Codable, Equatable {
    /// The card output channels (from 1, as in outputPatch) Binaural L and R play on; neither
    /// patched leaves the monitor off. A card output takes one Feral output, so these must not be
    /// patched to a speaker output too.
    public var left: Int?
    public var right: Int?
    /// The monitor's level in dB.
    public var gainDB: Double
    /// A folder of measured HRIRs (the MIT KEMAR "compact" set: elev0/H0e090a.wav and so on), or
    /// `headModel` for the built-in spherical head. None: the HRTF folder next to engine.json
    /// (~/Library/Application Support/Feral/HRTF) if it is there, else the head model.
    public var hrtf: String?

    /// `hrtf` for the built-in spherical head model.
    public static let headModel = "head model"

    public init(left: Int? = nil, right: Int? = nil, gainDB: Double = 0, hrtf: String? = nil) {
        self.left = left; self.right = right; self.gainDB = gainDB; self.hrtf = hrtf
    }

    enum CodingKeys: String, CodingKey { case left, right, gainDB, hrtf }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        left = try c.decodeIfPresent(Int.self, forKey: .left)
        right = try c.decodeIfPresent(Int.self, forKey: .right)
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        hrtf = try c.decodeIfPresent(String.self, forKey: .hrtf)
    }

    public var isOn: Bool { left != nil || right != nil }

    /// Checks the settings against the card channels Feral's outputs are patched to.
    public func check(outputChannels: [Int]) throws {
        for c in [left, right].compactMap({ $0 }) where c < 1 {
            throw ConfigError("monitor: left and right are card output channels, from 1")
        }
        if let l = left, l == right { throw ConfigError("monitor: Binaural L and R must be on different card outputs") }
        for c in [left, right].compactMap({ $0 }) {
            if let k = outputChannels.firstIndex(of: c) {
                throw ConfigError("monitor: card output \(c) already plays Feral output \(k + 1); a card output takes one output")
            }
        }
        guard (-60...20).contains(gainDB) else { throw ConfigError("monitor: gainDB must be from -60 to 20") }
    }

    /// The card channels for Binaural L and R (0 for none), as the patch lists them.
    public var channels: [Int] { [left ?? 0, right ?? 0] }
}

/// HRIRs by direction, at a sample rate.
public protocol HRIRSet {
    /// A description for the log and the app: "spherical head model", "KEMAR (710 directions)".
    var name: String { get }
    /// The pair for a direction as Feral measures it from the listener (azimuth positive to the
    /// left, elevation up), in degrees.
    func hrir(azimuth: Double, elevation: Double) -> (left: [Float], right: [Float])
}

/// A rigid sphere the size of a head (Brown and Duda, 1998): each ear is a first-order shelf that
/// lifts the highs on its own side and dulls them in the head's shadow, and the sound reaches the
/// ears at Woodworth's time difference. No pinna, so above and below sound alike and front and back
/// are easy to confuse; a measured set (`HRIRFolder`) is better when there is one.
public struct SphericalHead: HRIRSet {
    public var sampleRate: Double
    public var radius = 0.0875
    public var speedOfSound = 343.0
    public static let length = 256

    public init(sampleRate: Double) { self.sampleRate = sampleRate }

    public var name: String { "spherical head model" }

    public func hrir(azimuth: Double, elevation: Double) -> (left: [Float], right: [Float]) {
        let az = azimuth * .pi / 180, el = elevation * .pi / 180
        // Towards the left ear is +y (azimuth +90).
        let y = cos(el) * sin(az)
        return (ear(cosine: y), ear(cosine: -y))
    }

    /// One ear's response to a source at an angle θ from the ear's own axis (cos θ given).
    private func ear(cosine c: Double) -> [Float] {
        let theta = acos(max(-1, min(1, c)))
        // The shelf: (1 + jαω/2ω0) / (1 + jω/2ω0), ω0 = c/a, through the bilinear transform.
        let alpha = 1.05 + 0.95 * cos(theta * 180 / 150)
        let beta = 2 * speedOfSound / radius, k = 2 * sampleRate
        let b0 = (beta + alpha * k) / (beta + k), b1 = (beta - alpha * k) / (beta + k), a1 = (beta - k) / (beta + k)
        // Woodworth: in sight of the ear the path is shorter by a·cosθ; in the shadow longer by
        // a·(θ - 90°). Offset by a/c so it never goes below 0.
        let path = theta <= .pi / 2 ? -radius * cos(theta) : radius * (theta - .pi / 2)
        let delay = (path + radius) / speedOfSound * sampleRate + 1
        var h = [Double](repeating: 0, count: Self.length)
        // The shelf's impulse response, delayed by a fractional amount (linear interpolation).
        let whole = Int(delay), frac = delay - Double(whole)
        var x1 = 0.0, y1 = 0.0
        for n in 0..<(Self.length - whole - 1) {
            let x = n == 0 ? 1.0 : 0.0
            let v = b0 * x + b1 * x1 - a1 * y1
            x1 = x; y1 = v
            h[whole + n] += (1 - frac) * v
            h[whole + n + 1] += frac * v
        }
        return h.map { Float($0) }
    }
}

/// Measured HRIRs from a folder in the MIT KEMAR "compact" layout: elev{e}/H{e}e{aaa}a.wav, stereo
/// (left ear, right ear), azimuth clockwise from 0 to 180 (the right side; the left is the mirror
/// image). Each direction is played by its nearest measurement, resampled to the engine's rate.
public struct HRIRFolder: HRIRSet {
    struct Measurement {
        var azimuth: Double   // Feral's: positive to the left
        var elevation: Double
        var left: [Float], right: [Float]
    }
    var measurements: [Measurement] = []
    public let name: String

    public init(folder: URL, sampleRate: Double) throws {
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else {
            throw ConfigError("monitor: cannot read the HRTF folder \(folder.path)")
        }
        let pattern = try NSRegularExpression(pattern: "^H(-?[0-9]+)e([0-9]{3})a\\.wav$", options: [.caseInsensitive])
        var found: [Measurement] = []
        for case let url as URL in walk {
            let file = url.lastPathComponent
            let range = NSRange(file.startIndex..., in: file)
            guard let m = pattern.firstMatch(in: file, range: range),
                  let e = Range(m.range(at: 1), in: file).flatMap({ Double(file[$0]) }),
                  let a = Range(m.range(at: 2), in: file).flatMap({ Double(file[$0]) }) else { continue }
            let wav = try SimpleWAV(url: url)
            guard wav.channels.count == 2 else { throw ConfigError("monitor: \(file) is not stereo (the KEMAR compact set is)") }
            let l = Self.resample(wav.channels[0], from: wav.sampleRate, to: sampleRate)
            let r = Self.resample(wav.channels[1], from: wav.sampleRate, to: sampleRate)
            // KEMAR's azimuth is clockwise (to the right); Feral's is positive to the left.
            found.append(Measurement(azimuth: -a, elevation: e, left: l, right: r))
            if a > 0 && a < 180 { found.append(Measurement(azimuth: a, elevation: e, left: r, right: l)) }
        }
        guard !found.isEmpty else {
            throw ConfigError("monitor: no KEMAR files (elev0/H0e000a.wav and so on) in \(folder.path)")
        }
        // Level: the straight-ahead pair's energy to 1, as the head model's is near enough.
        let front = found.min { abs($0.azimuth) + abs($0.elevation) < abs($1.azimuth) + abs($1.elevation) }!
        let energy = front.left.reduce(0) { $0 + $1 * $1 }
        let scale = energy > 0 ? 1 / sqrt(energy) : 1
        measurements = found.map { (m: Measurement) -> Measurement in
            var scaled = m
            scaled.left = m.left.map { v in v * scale }
            scaled.right = m.right.map { v in v * scale }
            return scaled
        }
        name = "KEMAR (\(measurements.count) directions)"
    }

    public func hrir(azimuth: Double, elevation: Double) -> (left: [Float], right: [Float]) {
        let v = Self.unit(azimuth, elevation)
        var best = measurements[0], bestDot = -2.0
        for m in measurements {
            let u = Self.unit(m.azimuth, m.elevation)
            let d = u.0 * v.0 + u.1 * v.1 + u.2 * v.2
            if d > bestDot { bestDot = d; best = m }
        }
        return (best.left, best.right)
    }

    static func unit(_ az: Double, _ el: Double) -> (Double, Double, Double) {
        let a = az * .pi / 180, e = el * .pi / 180
        return (cos(e) * cos(a), cos(e) * sin(a), sin(e))
    }

    /// Band-limited resampling with a Hann-windowed sinc (16 taps each side).
    static func resample(_ x: [Float], from: Double, to: Double) -> [Float] {
        guard from != to, !x.isEmpty else { return x }
        let ratio = to / from
        let n = Int((Double(x.count) * ratio).rounded(.up))
        let cutoff = min(1, ratio), half = 16
        return (0..<n).map { i in
            let t = Double(i) / ratio
            var acc = 0.0
            for k in (Int(t) - half + 1)...(Int(t) + half) where k >= 0 && k < x.count {
                let d = t - Double(k)
                let s = d == 0 ? 1 : sin(.pi * d * cutoff) / (.pi * d * cutoff)
                let w = 0.5 + 0.5 * cos(.pi * d / Double(half))
                acc += Double(x[k]) * cutoff * s * (abs(d) < Double(half) ? w : 0)
            }
            return Float(acc)
        }
    }
}

/// Just enough of WAV to read HRIRs: 16-, 24- or 32-bit PCM, or 32-bit float.
struct SimpleWAV {
    var sampleRate: Double
    var channels: [[Float]]

    init(url: URL) throws {
        let data = [UInt8](try Data(contentsOf: url))
        func u32(_ i: Int) -> UInt32 { UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24 }
        func u16(_ i: Int) -> UInt16 { UInt16(data[i]) | UInt16(data[i + 1]) << 8 }
        let bad = ConfigError("monitor: \(url.lastPathComponent) is not a WAV file Feral can read")
        guard data.count >= 12, data[0..<4].elementsEqual("RIFF".utf8), data[8..<12].elementsEqual("WAVE".utf8) else { throw bad }
        var at = 12
        var format = 0, count = 0, rate = 0.0, bits = 0
        var body: Range<Int>?
        while at + 8 <= data.count {
            let size = Int(u32(at + 4)), start = at + 8
            guard start + size <= data.count else { break }
            if data[at..<at + 4].elementsEqual("fmt ".utf8), size >= 16 {
                format = Int(u16(start)); count = Int(u16(start + 2)); rate = Double(u32(start + 4)); bits = Int(u16(start + 14))
                if format == 0xFFFE, size >= 26 { format = Int(u16(start + 24)) }
            } else if data[at..<at + 4].elementsEqual("data".utf8) {
                body = start..<start + size
            }
            at = start + size + (size & 1)
        }
        guard let body, count > 0, rate > 0, [1, 3].contains(format), [16, 24, 32].contains(bits), format == 1 || bits == 32 else { throw bad }
        let width = bits / 8, frames = body.count / (width * count)
        var out = [[Float]](repeating: [Float](repeating: 0, count: frames), count: count)
        for f in 0..<frames {
            for c in 0..<count {
                let i = body.lowerBound + (f * count + c) * width
                let v: Float
                switch (format, bits) {
                case (3, _): v = Float(bitPattern: u32(i))
                case (_, 16): v = Float(Int16(bitPattern: u16(i))) / 32768
                case (_, 24):
                    let b0 = UInt32(data[i]) << 8, b1 = UInt32(data[i + 1]) << 16, b2 = UInt32(data[i + 2]) << 24
                    v = Float(Int32(bitPattern: b0 | b1 | b2) >> 8) / 8_388_608
                default: v = Float(Int32(bitPattern: u32(i))) / 2_147_483_648
                }
                out[c][f] = v
            }
        }
        sampleRate = rate
        channels = out
    }
}

/// One speaker as the monitor plays it.
public struct MonitorSpeaker: Equatable {
    /// Engine output, from 0.
    public var output: Int
    public var gain: Float
    /// Samples.
    public var delay: Int
    public var left: [Float], right: [Float]

    public init(output: Int, gain: Float, delay: Int, left: [Float], right: [Float]) {
        self.output = output; self.gain = gain; self.delay = delay; self.left = left; self.right = right
    }
}

extension ShowState {
    /// Every speaker as heard from the listening point: its direction's HRIRs, and a delay and gain
    /// for how much further it is than the nearest speaker. Speakers on the monitor's own outputs
    /// are left out.
    public func monitorSpeakers(hrirs: HRIRSet, sampleRate: Double, speedOfSound: Double, skipping: Set<Int> = []) -> [MonitorSpeaker] {
        let listener = system.listener
        let speakers = system.speakers.filter { !skipping.contains($0.output) }
        let polar = speakers.map { listener.polar(of: $0.position) }
        let nearest = max(0.5, polar.map(\.distance).min() ?? 1)
        let maxDelay = Int(FERAL_MONITOR_MAX_DELAY)
        return zip(speakers, polar).map { s, p in
            let d = max(nearest, p.distance)
            let h = hrirs.hrir(azimuth: p.azimuth, elevation: p.elevation)
            let delay = Int(((d - nearest) / speedOfSound * sampleRate).rounded())
            return MonitorSpeaker(output: s.output - 1, gain: Float(nearest / d), delay: min(delay, maxDelay), left: h.left, right: h.right)
        }
    }
}

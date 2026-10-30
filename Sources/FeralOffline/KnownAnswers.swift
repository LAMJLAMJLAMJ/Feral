import FeralCore
import FeralScene
import Foundation

/// Known-answer checks: generated signals rendered through the real render core, compared with
/// values worked out by hand from the formulas in the design. `feral-cli check` prints them and the
/// tests require every one to pass.
public enum KnownAnswers {
    public struct Result {
        public var name: String
        public var passed: Bool
        /// What was measured, so a failure says by how much.
        public var detail: String
    }

    public static func run() -> [Result] {
        [delayRenderer(), fractionalDelay(), delayGlide(), delayCrossfade(), gainRamp(), groupCrossfade(),
         vbap2D(), vbap3D(), vbapOpenDome(), vbapWidth(), dbap(), outputEQ(), outputDelayAndPolarity(),
         outputLimiter(), outputMute(), speedOfSound()]
    }

    // MARK: Helpers

    static let rate = 48_000.0
    static let frames = 64

    /// Renders `length` samples of one input through a core, one 64-frame buffer at a time, and
    /// returns every output. A silent buffer first gets the start-up fade-in out of the way.
    /// `change` is called before each buffer with the sample it starts at.
    static func play(_ core: RenderCore, outputs: Int, length: Int, input: (Int) -> Float,
                     change: (Int) -> Void = { _ in }) -> [[Float]] {
        let x = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let ys = (0..<outputs).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
        defer { x.deallocate(); ys.forEach { $0.deallocate() } }
        var result = [[Float]](repeating: [], count: outputs)
        let ins: [UnsafePointer<Float>?] = [UnsafePointer(x)]
        let outs: [UnsafeMutablePointer<Float>?] = ys
        x.initialize(repeating: 0, count: frames)
        feral_core_render(core.pointer, ins, 1, outs, Int32(outputs), Int32(frames))
        var start = 0
        while start < length {
            change(start)
            for k in 0..<frames { x[k] = input(start + k) }
            feral_core_render(core.pointer, ins, 1, outs, Int32(outputs), Int32(frames))
            for o in 0..<outputs { result[o] += UnsafeBufferPointer(start: ys[o], count: frames) }
            start += frames
        }
        return result
    }

    static func check(_ name: String, _ pairs: [(String, Double, Double)], tolerance: Double) -> Result {
        var worst = 0.0
        var lines: [String] = []
        for (label, got, want) in pairs {
            worst = max(worst, abs(got - want))
            lines.append("\(label) \(fmt(got)) (expected \(fmt(want)))")
        }
        return Result(name: name, passed: worst <= tolerance, detail: lines.joined(separator: ", "))
    }

    static func fmt(_ v: Double) -> String { String(format: abs(v) >= 100 ? "%.1f" : "%.4f", v) }

    static func vbapGains(_ speakers: [Position], source: Position, width: Double = 0, dimensions: Int32 = 0) -> [Float]? {
        let points = speakers.map { feral_point(x: $0.x, y: $0.y, z: $0.z) }
        guard let v = feral_vbap_create(points, Int32(points.count), feral_point(x: 0, y: 0, z: 0), dimensions) else { return nil }
        defer { feral_vbap_destroy(v) }
        var g = [Float](repeating: 0, count: points.count)
        feral_vbap_render(v, feral_point(x: source.x, y: source.y, z: source.z), width, 0, 0, &g)
        return g
    }

    /// One input through a delay tap to one output, with the design's delay motion.
    static func delayTap(delay: Double) -> RenderState {
        let s = RenderState(inputs: 1, outputs: 1)
        s.setMotion(.defaults(sampleRate: rate))
        s.addDelay(input: 0, output: 0, gain: 1, delay: delay)
        return s
    }

    // MARK: Delay renderer

    /// Three speakers 10, 20 and 40 ms of sound away from a source, rendered end to end through
    /// engine settings. Hand-computed: the nearest plays after the 10 ms precedence only (480
    /// samples), the others 10 and 30 ms later (960, 1920); levels 1, 1/2, 1/4 (6 dB per doubling).
    static func delayRenderer() -> Result {
        let c = feral_speed_of_sound(20)
        var config = EngineConfig(inputs: 1, outputs: 3)
        config.speakers = [SpeakerConfig(output: 1, position: Position(0.010 * c, 0, 0)),
                           SpeakerConfig(output: 2, position: Position(0, 0.020 * c, 0)),
                           SpeakerConfig(output: 3, position: Position(-0.040 * c, 0, 0))]
        config.groups = [GroupConfig(name: "Main", renderer: .delay, speakers: "1-3", precedenceMS: 10)]
        config.sources = [SourceConfig(input: 1, position: Position(0, 0, 0))]
        do {
            let r = try OfflineRenderer(config: config)
            let a = r.impulse(input: 1, seconds: 0.1)
            guard a.count == 3 else { return Result(name: "Delay renderer: arrival times and levels", passed: false, detail: "\(a.count) outputs reached") }
            return check("Delay renderer: arrival times and levels", [
                ("output 1 sample", a[0].milliseconds * 48, 480), ("output 2 sample", a[1].milliseconds * 48, 960),
                ("output 3 sample", a[2].milliseconds * 48, 1920),
                ("output 1 gain", pow(10, a[0].levelDB / 20), 1), ("output 2 gain", pow(10, a[1].levelDB / 20), 0.5),
                ("output 3 gain", pow(10, a[2].levelDB / 20), 0.25),
            ], tolerance: 1e-4)
        } catch {
            return Result(name: "Delay renderer: arrival times and levels", passed: false, detail: "\(error)")
        }
    }

    /// An impulse through a 100.5-sample delay: four-point Lagrange at half a sample gives
    /// -1/16, 9/16, 9/16, -1/16 on samples 99 to 102.
    static func fractionalDelay() -> Result {
        let core = RenderCore(sampleRate: rate)
        try! core.publish(delayTap(delay: 100.5))
        let y = play(core, outputs: 1, length: 256) { $0 == 0 ? 1 : 0 }[0]
        return check("Fractional delay (4-point Lagrange)", [
            ("y[99]", Double(y[99]), -1.0 / 16), ("y[100]", Double(y[100]), 9.0 / 16),
            ("y[101]", Double(y[101]), 9.0 / 16), ("y[102]", Double(y[102]), -1.0 / 16),
            ("y[98] + y[103]", Double(abs(y[98]) + abs(y[103])), 0),
        ], tolerance: 1e-6)
    }

    /// A delay moved from 480 to 490 samples glides at 0.5 %: after n samples it is
    /// 480 + 0.005 (n + 1). It moves a whole buffer's step at a time, so the last 0.08 samples take
    /// the 32nd buffer and it reaches 490 on sample 2048. A ramp input (x[n] = n / 1000) shows the delay
    /// on every sample exactly, since the interpolation is exact for straight lines.
    static func delayGlide() -> Result {
        let core = RenderCore(sampleRate: rate)
        try! core.publish(delayTap(delay: 480))
        let moveAt = 1280
        let y = play(core, outputs: 1, length: 4480, input: { Float($0) / 1000 }) { start in
            if start == moveAt { try! core.publish(delayTap(delay: 490)) }
        }[0]
        func delay(at n: Int) -> Double { Double(n) - Double(y[n]) * 1000 }
        return check("Delay glide (0.5 % pitch limit)", [
            ("delay before", delay(at: moveAt - 1), 480), ("after 100", delay(at: moveAt + 99), 480.5),
            ("after 1000", delay(at: moveAt + 999), 485), ("after 1984", delay(at: moveAt + 1983), 489.92),
            ("after 2048", delay(at: moveAt + 2047), 490),
            ("after 3000", delay(at: moveAt + 2999), 490),
        ], tolerance: 0.05)
    }

    /// A delay jumping by 10 ms (more than the 5 ms limit) crossfades over 30 ms (1440 samples):
    /// with the ramp input, the output is n - 480 - 480 w(n), where w rises from 0 to 1 as a
    /// raised cosine (one half at 720 samples).
    static func delayCrossfade() -> Result {
        let core = RenderCore(sampleRate: rate)
        try! core.publish(delayTap(delay: 480))
        let jumpAt = 1280
        let y = play(core, outputs: 1, length: 4480, input: { Float($0) / 1000 }) { start in
            if start == jumpAt { try! core.publish(delayTap(delay: 960)) }
        }[0]
        func weight(at n: Int) -> Double { (Double(n) - 480 - Double(y[n]) * 1000) / 480 }
        return check("Delay crossfade (jump over 5 ms)", [
            ("new weight before", weight(at: jumpAt - 1), 0), ("at 360", weight(at: jumpAt + 359), 0.1464),
            ("at 720", weight(at: jumpAt + 719), 0.5), ("at 1080", weight(at: jumpAt + 1079), 0.8536),
            ("at 1440", weight(at: jumpAt + 1439), 1), ("at 2000", weight(at: jumpAt + 1999), 1),
        ], tolerance: 0.01)
    }

    // MARK: Ramps

    /// A gain change from 1 to 0.5 ramps over one buffer: sample k of it is 1 - 0.5 (k + 1) / 64.
    static func gainRamp() -> Result {
        let core = RenderCore(sampleRate: rate)
        func state(_ g: Float) -> RenderState {
            let s = RenderState(inputs: 1, outputs: 1)
            s.addGain(input: 0, output: 0, gain: g)
            return s
        }
        try! core.publish(state(1))
        let y = play(core, outputs: 1, length: 256, input: { _ in 1 }) { start in
            if start == 128 { try! core.publish(state(0.5)) }
        }[0]
        return check("Gain change ramps over one buffer", [
            ("before", Double(y[127]), 1), ("first", Double(y[128]), 1 - 0.5 / 64),
            ("middle", Double(y[159]), 0.75), ("last", Double(y[191]), 0.5), ("after", Double(y[192]), 0.5),
        ], tolerance: 1e-5)
    }

    /// A source moved from output 1 to output 2 with a 50 ms (2400-sample) group crossfade: both are
    /// at one half after 1200 samples, and the move is done by the buffer that ends past 2400.
    static func groupCrossfade() -> Result {
        let core = RenderCore(sampleRate: rate)
        let a = RenderState(inputs: 1, outputs: 2)
        a.addGain(input: 0, output: 0, gain: 1)
        try! core.publish(a)
        let y = play(core, outputs: 2, length: 3200, input: { _ in 1 }) { start in
            if start == 0 {
                let b = RenderState(inputs: 1, outputs: 2)
                b.addGain(input: 0, output: 1, gain: 1)
                try! core.publish(b, fadeFrames: 2400)
            }
        }
        return check("Group crossfade (50 ms)", [
            ("old at 1200", Double(y[0][1199]), 0.5), ("new at 1200", Double(y[1][1199]), 0.5),
            ("old at 2432", Double(y[0][2431]), 0), ("new at 2432", Double(y[1][2431]), 1),
            ("sum on the way", Double(y[0][600] + y[1][600]), 1),
        ], tolerance: 1e-4)
    }

    // MARK: Panning

    /// Four speakers in a ring at 45, 135, 225 and 315 degrees, a source at 20 degrees: the pair
    /// 90 degrees apart gives cos 25 and sin 25 (0.9063, 0.4226).
    static func vbap2D() -> Result {
        let ring = [45.0, 135, 225, 315].map { a in Position(cos(a * .pi / 180), sin(a * .pi / 180), 0) }
        guard let g = vbapGains(ring, source: Position(3 * cos(20 * .pi / 180), 3 * sin(20 * .pi / 180), 0)) else {
            return Result(name: "VBAP 2D pair", passed: false, detail: "no layout")
        }
        return check("VBAP 2D pair", [
            ("45 deg", Double(g[0]), cos(25 * .pi / 180)), ("315 deg", Double(g[3]), sin(25 * .pi / 180)),
            ("135 deg", Double(g[1]), 0), ("225 deg", Double(g[2]), 0),
        ], tolerance: 1e-5)
    }

    /// Six speakers on the axes (an octahedron). A source along (1, 1, 1) plays equally from +x, +y
    /// and +z at 1/sqrt 3; a source on +x plays from that speaker alone.
    static func vbap3D() -> Result {
        let axes = [Position(1, 0, 0), Position(-1, 0, 0), Position(0, 1, 0), Position(0, -1, 0), Position(0, 0, 1), Position(0, 0, -1)]
        guard let g = vbapGains(axes, source: Position(2, 2, 2)), let h = vbapGains(axes, source: Position(5, 0, 0)) else {
            return Result(name: "VBAP 3D triangle", passed: false, detail: "no layout")
        }
        let third = 1 / 3.0.squareRoot()
        return check("VBAP 3D triangle", [
            ("+x", Double(g[0]), third), ("+y", Double(g[2]), third), ("+z", Double(g[4]), third),
            ("-x", Double(g[1]), 0), ("on +x", Double(h[0]), 1),
        ], tolerance: 1e-5)
    }

    /// A dome: 8 at the horizon, 4 at 45 degrees, one overhead, nothing below. A virtual speaker
    /// closes it underneath; a source straight down spreads evenly over the 8 horizon speakers
    /// (1/sqrt 8 each), and one between two horizon speakers plays from that pair at 1/sqrt 2.
    static func vbapOpenDome() -> Result {
        var dome = (0..<8).map { i in Position(cos(Double(i) * .pi / 4), sin(Double(i) * .pi / 4), 0) }
        dome += (0..<4).map { i in let a = Double(i) * .pi / 2 + .pi / 4; return Position(0.7071 * cos(a), 0.7071 * sin(a), 0.7071) }
        dome.append(Position(0, 0, 1))
        guard let down = vbapGains(dome, source: Position(0, 0, -1)),
              let between = vbapGains(dome, source: Position(cos(.pi / 8), sin(.pi / 8), 0)),
              let up = vbapGains(dome, source: Position(0, 0, 3)) else {
            return Result(name: "VBAP open dome", passed: false, detail: "no layout")
        }
        return check("VBAP open dome (virtual speaker below)", [
            ("down, horizon speaker 1", Double(down[0]), 1 / 8.0.squareRoot()),
            ("down, horizon speaker 5", Double(down[4]), 1 / 8.0.squareRoot()),
            ("down, overhead", Double(down[12]), 0),
            ("between 1 and 2", Double(between[0]), 1 / 2.0.squareRoot()),
            ("between 2 and 1", Double(between[1]), 1 / 2.0.squareRoot()),
            ("straight up", Double(up[12]), 1),
        ], tolerance: 1e-4)
    }

    /// Width spreads a source over more speakers, evenly to both sides, and keeps its power at 1.
    static func vbapWidth() -> Result {
        let ring = (0..<8).map { i in Position(cos(Double(i) * .pi / 4), sin(Double(i) * .pi / 4), 0) }
        guard let narrow = vbapGains(ring, source: Position(1, 0, 0)), let wide = vbapGains(ring, source: Position(1, 0, 0), width: 120) else {
            return Result(name: "VBAP width (MDAP)", passed: false, detail: "no layout")
        }
        let power = wide.reduce(0) { $0 + Double($1 * $1) }
        return check("VBAP width (MDAP)", [
            ("speakers playing, narrow", Double(narrow.filter { $0 > 1e-6 }.count), 1),
            // Nine directions from -60 to +60 degrees reach the speakers at 0, +-45 and +-90.
            ("speakers playing, 120 deg", Double(wide.filter { $0 > 1e-6 }.count), 5),
            ("left-right balance", Double(wide[1] - wide[7]), 0),
            ("power, 120 deg", power, 1),
        ], tolerance: 1e-5)
    }

    /// DBAP with speakers 1 m and 2 m from the source, no blur, 6 dB per doubling: gains in the ratio
    /// 2 to 1, power-normalised to 0.8944 and 0.4472.
    static func dbap() -> Result {
        let speakers = [feral_point(x: 1, y: 0, z: 0), feral_point(x: -2, y: 0, z: 0)]
        var g = [Float](repeating: 0, count: 2)
        feral_dbap_render(speakers, nil, 2, feral_point(x: 0, y: 0, z: 0), 0, 6.0206, &g)
        return check("DBAP gains", [("1 m", Double(g[0]), 2 / 5.0.squareRoot()), ("2 m", Double(g[1]), 1 / 5.0.squareRoot())],
                     tolerance: 1e-4)
    }

    // MARK: Output processing

    /// A speaker with one +6.02 dB peak band at 1 kHz doubles a 1 kHz sine.
    static func outputEQ() -> Result {
        let speaker = SpeakerConfig(output: 1, position: Position(0, 0, 0), eq: [EQBand(.peak, hz: 1000, q: 1, gainDB: 6.0206)])
        let core = RenderCore(sampleRate: rate)
        let s = RenderState(inputs: 1, outputs: 1)
        s.addGain(input: 0, output: 0, gain: 1)
        s.setOutput(0, SpatialRenderer.outputParams(speaker, sampleRate: rate))
        try! core.publish(s)
        let y = play(core, outputs: 1, length: 24_000) { Float(sin(2 * .pi * 1000 * Double($0) / rate)) }[0]
        let peak = y[12_000...].map { abs($0) }.max() ?? 0
        let design = Biquad(speaker.eq[0], sampleRate: rate).responseDB(at: 1000, sampleRate: rate)
        return check("Output EQ (peak band)", [("1 kHz gain", Double(peak), 2), ("designed response dB", design, 6.0206)],
                     tolerance: 0.01)
    }

    /// A speaker 2.5 ms late with its polarity flipped: an impulse comes out 120 samples later, at -1.
    static func outputDelayAndPolarity() -> Result {
        let speaker = SpeakerConfig(output: 1, position: Position(0, 0, 0), delayMS: 2.5, invert: true)
        let core = RenderCore(sampleRate: rate)
        let s = RenderState(inputs: 1, outputs: 1)
        s.addGain(input: 0, output: 0, gain: 1)
        s.setOutput(0, SpatialRenderer.outputParams(speaker, sampleRate: rate))
        try! core.publish(s)
        let y = play(core, outputs: 1, length: 256) { $0 == 0 ? 1 : 0 }[0]
        let peak = y.indices.max { abs(y[$0]) < abs(y[$1]) } ?? 0
        return check("Output alignment delay and polarity", [("arrival sample", Double(peak), 120), ("level", Double(y[peak]), -1)],
                     tolerance: 1e-6)
    }

    /// A full-scale sine into a speaker limited at -6.02 dB: no sample leaves above 0.5.
    static func outputLimiter() -> Result {
        let speaker = SpeakerConfig(output: 1, position: Position(0, 0, 0), limiterDB: -6.0206)
        let core = RenderCore(sampleRate: rate)
        let s = RenderState(inputs: 1, outputs: 1)
        s.addGain(input: 0, output: 0, gain: 1)
        s.setOutput(0, SpatialRenderer.outputParams(speaker, sampleRate: rate))
        try! core.publish(s)
        let y = play(core, outputs: 1, length: 9600) { Float(sin(2 * .pi * 100 * Double($0) / rate)) }[0]
        let peak = y.map { abs($0) }.max() ?? 0
        return check("Output limiter (no look-ahead)", [("peak", Double(peak), 0.5)], tolerance: 1e-3)
    }

    /// Muting an output ramps it to silence over one buffer.
    static func outputMute() -> Result {
        let core = RenderCore(sampleRate: rate)
        func state(muted: Bool) -> RenderState {
            let s = RenderState(inputs: 1, outputs: 1)
            s.addGain(input: 0, output: 0, gain: 1)
            var p = OutputParams()
            p.mute = muted
            s.setOutput(0, p)
            return s
        }
        try! core.publish(state(muted: false))
        let y = play(core, outputs: 1, length: 256, input: { _ in 1 }) { start in
            if start == 128 { try! core.publish(state(muted: true)) }
        }[0]
        return check("Output mute ramps", [("before", Double(y[127]), 1), ("middle", Double(y[159]), 0.5),
                                           ("end", Double(y[191]), 0), ("after", Double(y[255]), 0)], tolerance: 1e-5)
    }

    /// 331.3 m/s at 0 degrees C; 343.2 m/s at 20.
    static func speedOfSound() -> Result {
        check("Speed of sound from temperature", [("0 C", feral_speed_of_sound(0), 331.3), ("20 C", feral_speed_of_sound(20), 343.2)],
              tolerance: 0.05)
    }
}

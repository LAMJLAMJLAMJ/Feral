import FeralCore
import Foundation

/// The control thread's handle on the C++ render core. It owns the core; the audio side reaches the
/// same core through `pointer`, never through this class.
public final class RenderCore {
    public let pointer: OpaquePointer
    public let sampleRate: Double

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        pointer = feral_core_create(sampleRate)
    }

    deinit { feral_core_destroy(pointer) }

    /// The longest delay the core plays, in samples.
    public var maxDelay: Double { feral_core_max_delay(pointer) }

    /// Publishes a routing as the next render state. The audio thread ramps to it over one buffer.
    public func publish(_ routing: Routing) {
        let status = routing.gains.withUnsafeBufferPointer {
            feral_core_publish_gains(pointer, $0.baseAddress, Int32(routing.inputs), Int32(routing.outputs))
        }
        precondition(status == 0, "routing sizes are checked when it is built")
    }

    /// Publishes a render state. Gain changes take `fadeFrames` (0: one buffer; more for a renderer or
    /// group change). Throws when the state has two delay taps for one input and output; nothing
    /// changes then.
    public func publish(_ state: RenderState, fadeFrames: Int = 0) throws {
        guard let handle = state.take() else { preconditionFailure("a render state can be published once") }
        if feral_core_publish(pointer, handle, Int32(fadeFrames)) != 0 {
            throw ConfigError("a source reaches one speaker through two delay groups; a speaker can be in only one Delay group")
        }
    }

    /// Frees render states the audio thread no longer uses. Returns how many.
    @discardableResult
    public func collect() -> Int { Int(feral_core_collect(pointer)) }

    public var liveStates: Int { Int(feral_core_live_states(pointer)) }

    /// Call once the audio thread has stopped (after AudioDeviceStop returns).
    public func audioDetached() { feral_core_audio_detached(pointer) }

    /// Replaces input 1 with a generated test signal, or puts it back with `.off`.
    public func setTestSignal(_ kind: TestSignal, levelDB: Double, sineHz: Double = 1000) {
        let code: Int32
        switch kind {
        case .off: code = Int32(FERAL_TEST_OFF)
        case .pink: code = Int32(FERAL_TEST_PINK)
        case .sine: code = Int32(FERAL_TEST_SINE)
        }
        feral_core_set_test_signal(pointer, code, Float(levelDB), Float(sineHz))
    }

    public struct Stats: Equatable {
        public var buffers: UInt64
        public var lateBuffers: UInt64
        public var stateSwaps: UInt64
        public var currentState: UInt64
        public var maxLoad: Float
        /// Taps playing now, including ones still fading out.
        public var activeTaps: Int
    }

    public func stats(resetMaxLoad: Bool = false) -> Stats {
        var s = feral_core_stats()
        feral_core_get_stats(pointer, &s, resetMaxLoad ? 1 : 0)
        return Stats(buffers: s.buffers, lateBuffers: s.late_buffers, stateSwaps: s.state_swaps,
                     currentState: s.current_state, maxLoad: s.max_load, activeTaps: Int(s.active_taps))
    }
}

/// A render state being built on the control thread: taps, output processing and delay motion.
/// Publish it with `RenderCore.publish(_:fadeFrames:)`; after that it is the core's.
public final class RenderState {
    private var handle: OpaquePointer?
    public let inputs: Int
    public let outputs: Int

    /// inputs and outputs up to 256 each.
    public init(inputs: Int, outputs: Int) {
        precondition((0...Routing.maxChannels).contains(inputs) && (0...Routing.maxChannels).contains(outputs))
        self.inputs = inputs
        self.outputs = outputs
        handle = feral_state_create(Int32(inputs), Int32(outputs))
    }

    deinit { if let handle { feral_state_destroy(handle) } }

    fileprivate func take() -> OpaquePointer? {
        defer { handle = nil }
        return handle
    }

    private var live: OpaquePointer {
        guard let handle else { preconditionFailure("this render state was already published") }
        return handle
    }

    /// An input straight to an output (both from 0) at a linear gain. Gains for the same pair add up.
    public func addGain(input: Int, output: Int, gain: Float) {
        precondition(feral_state_add_gain(live, Int32(input), Int32(output), gain) == 0, "channel out of range")
    }

    /// An input through its delay line to an output (both from 0), delay in samples.
    public func addDelay(input: Int, output: Int, gain: Float, delay: Double) {
        precondition(feral_state_add_delay(live, Int32(input), Int32(output), gain, Float(delay)) == 0, "channel out of range")
    }

    public func setOutput(_ output: Int, _ params: OutputParams) {
        var p = params.cValue
        precondition(feral_state_set_output(live, Int32(output), &p) == 0, "output out of range")
    }

    public func setMotion(_ motion: DelayMotion) {
        var m = feral_motion_params(glide_rate: Float(motion.glideRate), jump: Float(motion.jump),
                                    crossfade: Float(motion.crossfade))
        feral_state_set_motion(live, &m)
    }

    public var tapCount: Int { Int(feral_state_tap_count(live)) }
}

/// How delays move when they change, in samples (see feral_motion_params).
public struct DelayMotion: Equatable {
    /// Most change per sample while gliding (0.005 is a 0.5 % pitch shift).
    public var glideRate: Double
    /// A larger change than this crossfades instead of gliding.
    public var jump: Double
    /// The crossfade's length.
    public var crossfade: Double

    public init(glideRate: Double, jump: Double, crossfade: Double) {
        self.glideRate = glideRate
        self.jump = jump
        self.crossfade = crossfade
    }

    /// The design's defaults: glide 0.5 %, jump 5 ms, crossfade 30 ms.
    public static func defaults(sampleRate: Double) -> DelayMotion {
        DelayMotion(glideRate: 0.005, jump: 0.005 * sampleRate, crossfade: 0.030 * sampleRate)
    }
}

/// One biquad section, normalised so a0 is 1.
public struct Biquad: Equatable {
    public var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float

    public static let flat = Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    /// Designs one EQ band (RBJ Audio EQ Cookbook) at a sample rate.
    public init(_ band: EQBand, sampleRate: Double) {
        var c = feral_biquad()
        feral_biquad_design(band.type.code, band.hz, band.q ?? band.type.defaultQ, band.gainDB, sampleRate, &c)
        self.init(b0: c.b0, b1: c.b1, b2: c.b2, a1: c.a1, a2: c.a2)
    }

    /// The magnitude response in dB at a frequency.
    public func responseDB(at hz: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * hz / sampleRate
        func mag(_ c0: Double, _ c1: Double, _ c2: Double) -> Double {
            let re = c0 + c1 * cos(w) + c2 * cos(2 * w), im = -(c1 * sin(w) + c2 * sin(2 * w))
            return (re * re + im * im).squareRoot()
        }
        return 20 * log10(mag(Double(b0), Double(b1), Double(b2)) / mag(1, Double(a1), Double(a2)))
    }
}

/// One output's processing (see feral_output_params): alignment delay, EQ, trim and polarity,
/// limiter, mute.
public struct OutputParams: Equatable {
    public static let bands = Int(FERAL_EQ_BANDS)

    /// Alignment delay in samples.
    public var delay: Double = 0
    /// Up to `bands` sections; missing ones pass through.
    public var eq: [Biquad] = []
    /// Trim times polarity, linear.
    public var gain: Float = 1
    /// Linear peak threshold; 0 is off.
    public var limiterThreshold: Float = 0
    /// Samples to let go by 20 dB.
    public var limiterRelease: Float = 9600
    public var mute = false

    public init() {}

    var cValue: feral_output_params {
        var p = feral_output_defaults()
        p.delay = Float(delay)
        withUnsafeMutableBytes(of: &p.eq) { raw in
            let bands = raw.bindMemory(to: feral_biquad.self)
            for (i, b) in eq.prefix(OutputParams.bands).enumerated() {
                bands[i] = feral_biquad(b0: b.b0, b1: b.b1, b2: b.b2, a1: b.a1, a2: b.a2)
            }
        }
        p.gain = gain
        p.limiter_threshold = limiterThreshold
        p.limiter_release = limiterRelease
        p.mute = mute ? 1 : 0
        return p
    }
}

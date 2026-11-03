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

    /// Render workers for a Mac (or other machine): one fewer than its performance cores, since the
    /// audio thread does its share too, at most 32.
    public static var automaticWorkers: Int {
        #if os(macOS)
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) == 0, cores > 0 {
            return max(0, min(Int(cores) - 1, Int(FERAL_MAX_WORKERS)))
        }
        #endif
        return max(0, min(ProcessInfo.processInfo.activeProcessorCount - 1, Int(FERAL_MAX_WORKERS)))
    }

    /// Starts render workers that share the outputs' work with the audio thread. Call before the
    /// audio starts; returns how many run.
    @discardableResult
    public func startWorkers(_ count: Int) -> Int { Int(feral_core_start_workers(pointer, Int32(max(0, count)))) }

    public var workers: Int { Int(feral_core_workers(pointer)) }

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

    /// Linear levels per channel (see feral_core_read_meters).
    public struct Levels: Equatable {
        /// The highest absolute sample since the last read.
        public var inputPeak: [Float]
        /// RMS over about 300 ms.
        public var inputRMS: [Float]
        public var outputPeak: [Float]
        public var outputRMS: [Float]
    }

    /// Reads the first `inputs` inputs' and `outputs` outputs' meters, and starts the peaks again.
    /// One reader at a time.
    public func readMeters(inputs: Int, outputs: Int) -> Levels {
        let i = max(0, min(inputs, Routing.maxChannels)), o = max(0, min(outputs, Routing.maxChannels))
        var inPeak = [Float](repeating: 0, count: i), inRMS = [Float](repeating: 0, count: i)
        var outPeak = [Float](repeating: 0, count: o), outRMS = [Float](repeating: 0, count: o)
        inPeak.withUnsafeMutableBufferPointer { ip in
            inRMS.withUnsafeMutableBufferPointer { ir in
                outPeak.withUnsafeMutableBufferPointer { op in
                    outRMS.withUnsafeMutableBufferPointer { or in
                        feral_core_read_meters(pointer, ip.baseAddress, ir.baseAddress, Int32(i),
                                               op.baseAddress, or.baseAddress, Int32(o))
                    }
                }
            }
        }
        return Levels(inputPeak: inPeak, inputRMS: inRMS, outputPeak: outPeak, outputRMS: outRMS)
    }

    /// Each input compressor's deepest gain reduction in dB since the last read (0 or more), for the
    /// first `inputs` inputs. One reader at a time.
    public func readReduction(inputs: Int) -> [Float] {
        let i = max(0, min(inputs, Routing.maxChannels))
        var out = [Float](repeating: 0, count: i)
        out.withUnsafeMutableBufferPointer { feral_core_read_reduction(pointer, $0.baseAddress, Int32(i)) }
        return out
    }

    /// The same per multiband band: for each input, low, mid and high.
    public func readBandReduction(inputs: Int) -> [[Float]] {
        let i = max(0, min(inputs, Routing.maxChannels)), n = Int(FERAL_COMP_BANDS)
        var flat = [Float](repeating: 0, count: i * n)
        flat.withUnsafeMutableBufferPointer { feral_core_read_band_reduction(pointer, $0.baseAddress, Int32(i)) }
        return (0..<i).map { Array(flat[$0 * n ..< ($0 + 1) * n]) }
    }

    /// Hands the core a new monitor: the two outputs (from 0; none for neither turns it off), its
    /// linear gain, and the speakers it hears. Older monitors are freed by `collect`.
    public func setMonitor(left: Int?, right: Int?, gain: Float, speakers: [MonitorSpeaker]) {
        guard let m = feral_monitor_create(Int32(left ?? -1), Int32(right ?? -1), gain) else { return }
        for s in speakers {
            let n = min(s.left.count, s.right.count)
            guard n > 0 else { continue }
            s.left.withUnsafeBufferPointer { l in
                s.right.withUnsafeBufferPointer { r in
                    _ = feral_monitor_add_speaker(m, Int32(s.output), s.gain, Int32(s.delay), l.baseAddress, r.baseAddress, Int32(n))
                }
            }
        }
        feral_core_set_monitor(pointer, m)
    }

    /// What the monitor hears from an input (from 0): in the solo, and on PFL at a linear gain per ear.
    public func setListen(input: Int, solo: Bool, pflLeft: Float, pflRight: Float) {
        feral_core_set_listen(pointer, Int32(input), solo ? 1 : 0, pflLeft, pflRight)
    }

    public func clearListen() { feral_core_clear_listen(pointer) }

    /// Picks the input (from 0) the analysis tap keeps, or none.
    public func setAnalysisInput(_ input: Int?) { feral_core_set_analysis_input(pointer, Int32(input ?? -1)) }

    /// The analysed input's newest samples before and after its EQ and compressor, and how many the
    /// tap has taken since the input was picked.
    public func readAnalysis(frames: Int) -> (pre: [Float], post: [Float], written: UInt64) {
        let n = max(0, min(frames, Int(FERAL_ANALYSIS_FRAMES)))
        var pre = [Float](repeating: 0, count: n), post = [Float](repeating: 0, count: n)
        let written = pre.withUnsafeMutableBufferPointer { a in
            post.withUnsafeMutableBufferPointer { b in feral_core_read_analysis(pointer, a.baseAddress, b.baseAddress, Int32(n)) }
        }
        return (pre, post, written)
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

    /// An input's EQ and compressor (input from 0).
    public func setInput(_ input: Int, _ params: InputParams) {
        var p = params.cValue
        precondition(feral_state_set_input(live, Int32(input), &p) == 0, "input out of range")
    }

    public func setMotion(_ motion: DelayMotion) {
        var m = feral_motion_params(glide_rate: Float(motion.glideRate), jump: Float(motion.jump),
                                    crossfade: Float(motion.crossfade))
        feral_state_set_motion(live, &m)
    }

    public var tapCount: Int { Int(feral_state_tap_count(live)) }

    /// A room's late tail (room from 0, below FERAL_MAX_ROOMS).
    public func setRoom(_ room: Int, _ params: RoomParams) {
        var p = params.cValue
        precondition(feral_state_set_room(live, Int32(room), &p) == 0, "room out of range")
    }

    /// An input's send to a room, linear.
    public func addRoomSend(input: Int, room: Int, gain: Float) {
        precondition(feral_state_add_room_send(live, Int32(input), Int32(room), gain) == 0, "input or room out of range")
    }

    /// One of a room's tail lines to an output, linear.
    public func addRoomOutput(room: Int, line: Int, output: Int, gain: Float) {
        precondition(feral_state_add_room_output(live, Int32(room), Int32(line), Int32(output), gain) == 0, "room output out of range")
    }

    /// An input's early reflections: delays in samples, linear gains, and the wall filter they share.
    public func setReflections(input: Int, delays: [Double], gains: [Float], filter: [Biquad]) {
        let n = min(delays.count, gains.count, Int(FERAL_MAX_REFLECTIONS))
        let d = delays.prefix(n).map { Float($0) }
        let f = (0..<Int(FERAL_REFLECTION_FILTER)).map { k -> feral_biquad in
            guard k < filter.count else { return feral_biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0) }
            let b = filter[k]
            return feral_biquad(b0: b.b0, b1: b.b1, b2: b.b2, a1: b.a1, a2: b.a2)
        }
        let g = Array(gains.prefix(n))
        let status = d.withUnsafeBufferPointer { dp in
            g.withUnsafeBufferPointer { gp in
                f.withUnsafeBufferPointer { fp in
                    feral_state_set_reflections(live, Int32(input), Int32(n), dp.baseAddress, gp.baseAddress, fp.baseAddress)
                }
            }
        }
        precondition(status == 0, "input out of range")
    }

    /// Pans one of an input's reflections to an output, linear.
    public func addReflectionOutput(input: Int, reflection: Int, output: Int, gain: Float) {
        precondition(feral_state_add_reflection_output(live, Int32(input), Int32(reflection), Int32(output), gain) == 0,
                     "reflection output out of range")
    }
}

/// A room's late tail as the core runs it (see feral_room_params).
public struct RoomParams: Equatable {
    public var on = false
    /// RT60 in seconds below the low crossover, between, and above the high one.
    public var decay: (low: Double, mid: Double, high: Double) = (2, 2, 2)
    public var crossoverLowHz = 177.0
    public var crossoverHighHz = 5657.0
    /// Samples.
    public var predelay = 0.0
    /// The lines' mean length in samples.
    public var lineLength: Double
    public var diffusion = 0.7
    public var modulation = 0.5

    public init(sampleRate: Double) { lineLength = 0.02 * sampleRate }

    public static func == (a: RoomParams, b: RoomParams) -> Bool {
        a.on == b.on && a.decay == b.decay && a.crossoverLowHz == b.crossoverLowHz && a.crossoverHighHz == b.crossoverHighHz
            && a.predelay == b.predelay && a.lineLength == b.lineLength && a.diffusion == b.diffusion && a.modulation == b.modulation
    }

    var cValue: feral_room_params {
        var p = feral_room_defaults(48_000)
        p.on = on ? 1 : 0
        p.decay = (Float(decay.low), Float(decay.mid), Float(decay.high))
        p.crossover = (Float(crossoverLowHz), Float(crossoverHighHz))
        p.predelay = Float(predelay)
        p.line_length = Float(lineLength)
        p.diffusion = Float(diffusion)
        p.modulation = Float(modulation)
        return p
    }
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

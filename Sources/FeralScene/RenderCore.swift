import FeralCore

/// The control thread's handle on the C++ render core. It owns the core; the audio side reaches the
/// same core through `pointer`, never through this class.
public final class RenderCore {
    public let pointer: OpaquePointer

    public init(sampleRate: Double) {
        pointer = feral_core_create(sampleRate)
    }

    deinit { feral_core_destroy(pointer) }

    /// Publishes a routing as the next render state. The audio thread ramps to it over one buffer.
    public func publish(_ routing: Routing) {
        let status = routing.gains.withUnsafeBufferPointer {
            feral_core_publish_gains(pointer, $0.baseAddress, Int32(routing.inputs), Int32(routing.outputs))
        }
        precondition(status == 0, "routing sizes are checked when it is built")
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
    }

    public func stats(resetMaxLoad: Bool = false) -> Stats {
        var s = feral_core_stats()
        feral_core_get_stats(pointer, &s, resetMaxLoad ? 1 : 0)
        return Stats(buffers: s.buffers, lateBuffers: s.late_buffers, stateSwaps: s.state_swaps,
                     currentState: s.current_state, maxLoad: s.max_load)
    }
}

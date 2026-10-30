import FeralCore
import FeralScene
import Foundation
import XCTest

final class DelayTapTests: XCTestCase {
    func delayState(_ delay: Double, gain: Float = 1) -> RenderState {
        let s = RenderState(inputs: 1, outputs: 1)
        s.addDelay(input: 0, output: 0, gain: gain, delay: delay)
        return s
    }

    func testWholeSampleDelayIsExact() throws {
        let core = RenderCore(sampleRate: 48_000)
        try core.publish(delayState(100))
        let input = TestBuffers(channels: 1, frames: 64) { _, _ in 0 }
        let output = TestBuffers(channels: 1, frames: 64)
        render(core.pointer, input, output) // fade-in
        var y: [Float] = []
        for b in 0..<4 {
            input.channels[0][0] = b == 0 ? 1 : 0
            render(core.pointer, input, output)
            y += output[0]
        }
        XCTAssertEqual(y[100], 1)
        XCTAssertEqual(y.filter { $0 != 0 }.count, 1)
    }

    func testTwoDelayTapsForOnePairAreRefused() {
        let core = RenderCore(sampleRate: 48_000)
        let s = RenderState(inputs: 1, outputs: 1)
        s.addDelay(input: 0, output: 0, gain: 1, delay: 10)
        s.addDelay(input: 0, output: 0, gain: 1, delay: 20)
        XCTAssertThrowsError(try core.publish(s))
        XCTAssertEqual(core.liveStates, 0, "nothing was published")
    }

    func testGainTapsForOnePairAddUp() throws {
        let core = RenderCore(sampleRate: 48_000)
        let s = RenderState(inputs: 1, outputs: 1)
        s.addGain(input: 0, output: 0, gain: 0.25)
        s.addGain(input: 0, output: 0, gain: 0.5)
        try core.publish(s)
        let input = TestBuffers(channels: 1, frames: 64) { _, _ in 1 }
        let output = TestBuffers(channels: 1, frames: 64)
        render(core.pointer, input, output)
        render(core.pointer, input, output)
        XCTAssertEqual(output[0], [Float](repeating: 0.75, count: 64))
        XCTAssertEqual(core.stats().activeTaps, 1)
    }

    /// Buffers longer than the core's 4096-frame block are rendered in pieces, seamlessly.
    func testLongBuffersRenderInPieces() throws {
        let core = RenderCore(sampleRate: 48_000)
        try core.publish(delayState(1000))
        let frames = 10_000
        let input = TestBuffers(channels: 1, frames: frames) { _, n in Float(n) }
        let output = TestBuffers(channels: 1, frames: frames)
        render(core.pointer, input, output)
        render(core.pointer, input, output)
        let y = output[0]
        for n in [0, 999, 1000, 4095, 4096, 9999] {
            // Each sample is the input 1000 samples earlier (the first buffer's tail, then this one's).
            let expected = n >= 1000 ? Float(n - 1000) : Float(frames + n - 1000)
            XCTAssertEqual(y[n], expected, "sample \(n)")
        }
    }

    /// Delays longer than the core holds are clamped to its maximum (1 s).
    func testDelaysAreClamped() throws {
        let core = RenderCore(sampleRate: 48_000)
        XCTAssertEqual(core.maxDelay, 48_000)
        try core.publish(delayState(1_000_000))
        let input = TestBuffers(channels: 1, frames: 4000) { _, _ in 0 }
        let output = TestBuffers(channels: 1, frames: 4000)
        render(core.pointer, input, output)
        input.channels[0][0] = 1
        var at = -1
        for b in 0..<13 {
            render(core.pointer, input, output)
            input.channels[0][0] = 0
            if let k = output[0].firstIndex(of: 1) { at = b * 4000 + k }
        }
        XCTAssertEqual(at, 48_000)
    }

    /// Detaching clears the delay lines: nothing from before a device stop plays after it restarts.
    func testDetachClearsDelayLines() throws {
        let core = RenderCore(sampleRate: 48_000)
        try core.publish(delayState(200))
        let input = TestBuffers(channels: 1, frames: 64) { _, _ in 1 }
        let output = TestBuffers(channels: 1, frames: 64)
        for _ in 0..<4 { render(core.pointer, input, output) }
        core.audioDetached()
        let silence = TestBuffers(channels: 1, frames: 64)
        for _ in 0..<8 {
            render(core.pointer, silence, output)
            XCTAssertEqual(output[0], [Float](repeating: 0, count: 64))
        }
    }

    /// 128 sources each through 32 delayed speakers (4096 interpolated taps), with 8 EQ bands, a
    /// limiter and an alignment delay on all 128 outputs, at a 64-frame buffer.
    func testDelayRenderingFitsTheBuffer() throws {
        #if DEBUG
        throw XCTSkip("timing is only meaningful in a release build (swift test -c release)")
        #else
        let core = RenderCore(sampleRate: 48_000)
        let s = RenderState(inputs: 128, outputs: 128)
        for i in 0..<128 { for k in 0..<32 { s.addDelay(input: i, output: (i + k * 4) % 128, gain: 0.01, delay: 100 + Double(i) * 3.37 + Double(k) * 7.11) } }
        var p = OutputParams()
        p.delay = 10.5
        p.eq = (1...8).map { Biquad(EQBand(.peak, hz: 100 * Double($0), gainDB: -3), sampleRate: 48_000) }
        p.limiterThreshold = 0.9
        for o in 0..<128 { s.setOutput(o, p) }
        try core.publish(s)
        let input = TestBuffers(channels: 128, frames: 64) { c, n in Float(c + n) * 1e-4 }
        let output = TestBuffers(channels: 128, frames: 64)
        for _ in 0..<500 { render(core.pointer, input, output) }
        let started = Date()
        for _ in 0..<2000 { render(core.pointer, input, output) }
        let average = Date().timeIntervalSince(started) / 2000
        print("128 sources x 32 delayed speakers + output processing, 64 frames: "
              + "\(String(format: "%.1f", average * 1e6)) µs per buffer of 1333 µs")
        XCTAssertEqual(core.stats().activeTaps, 4096)
        XCTAssertLessThan(average, 0.6 * 64 / 48_000)
        #endif
    }
}

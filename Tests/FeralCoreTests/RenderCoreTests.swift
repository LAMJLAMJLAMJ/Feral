import FeralCore
import FeralScene
import Foundation
import XCTest

final class RenderCoreTests: XCTestCase {
    let frames = 64

    /// A different, recognisable signal on every input.
    func signal(_ channel: Int, _ n: Int) -> Float { Float(channel + 1) * 0.01 + Float(n) * 0.0001 }

    func testSilentBeforeAnyRouting() {
        let core = RenderCore(sampleRate: 48_000)
        let input = TestBuffers(channels: 2, frames: frames) { _, _ in 1 }
        let output = TestBuffers(channels: 2, frames: frames) { _, _ in 9 }
        render(core.pointer, input, output)
        XCTAssertEqual(output[0], [Float](repeating: 0, count: frames))
        XCTAssertEqual(output[1], [Float](repeating: 0, count: frames))
    }

    func testPassthroughFadesInThenIsExact() throws {
        let core = RenderCore(sampleRate: 48_000)
        core.publish(try Routing(routes: [], inputs: 128, outputs: 128))
        let input = TestBuffers(channels: 128, frames: frames, fill: signal)
        let output = TestBuffers(channels: 128, frames: frames)

        // The first buffer after start fades in from silence.
        render(core.pointer, input, output)
        for c in [0, 63, 127] {
            for n in [0, frames / 2, frames - 1] {
                let expected = signal(c, n) * Float(n + 1) / Float(frames)
                XCTAssertEqual(output[c][n], expected, accuracy: 1e-6)
            }
        }
        // Then every output is its input, exactly.
        render(core.pointer, input, output)
        for c in 0..<128 { XCTAssertEqual(output[c], input[c], "output \(c + 1)") }
    }

    func testMatrixSumsAndScales() throws {
        let core = RenderCore(sampleRate: 48_000)
        let routing = try Routing(routes: [
            Route(inputs: "1", outputs: "1-2"),                 // input 1 to outputs 1 and 2
            Route(inputs: "2-3", outputs: "3", gainDB: -6.0206), // inputs 2 and 3 summed at half gain
        ], inputs: 3, outputs: 4)
        core.publish(routing)
        let input = TestBuffers(channels: 3, frames: frames, fill: signal)
        let output = TestBuffers(channels: 4, frames: frames)
        render(core.pointer, input, output)
        render(core.pointer, input, output)
        for n in 0..<frames {
            XCTAssertEqual(output[0][n], signal(0, n), accuracy: 1e-7)
            XCTAssertEqual(output[1][n], signal(0, n), accuracy: 1e-7)
            XCTAssertEqual(output[2][n], 0.5 * (signal(1, n) + signal(2, n)), accuracy: 1e-6)
            XCTAssertEqual(output[3][n], 0)
        }
    }

    func testNewStateRampsOverOneBuffer() throws {
        let core = RenderCore(sampleRate: 48_000)
        core.publish(try Routing(routes: [Route(inputs: "1", outputs: "1")], inputs: 1, outputs: 1))
        let input = TestBuffers(channels: 1, frames: frames) { _, _ in 1 }
        let output = TestBuffers(channels: 1, frames: frames)
        render(core.pointer, input, output)
        render(core.pointer, input, output)
        XCTAssertEqual(output[0], [Float](repeating: 1, count: frames))

        core.publish(try Routing(routes: [Route(inputs: "1", outputs: "1", gainDB: -6.0206)], inputs: 1, outputs: 1))
        render(core.pointer, input, output)
        for n in 0..<frames {
            XCTAssertEqual(output[0][n], 1 - 0.5 * Float(n + 1) / Float(frames), accuracy: 1e-5, "sample \(n)")
        }
        render(core.pointer, input, output)
        for n in 0..<frames { XCTAssertEqual(output[0][n], 0.5, accuracy: 1e-5) }

        // A route that goes away ramps down to silence rather than stopping dead.
        core.publish(try Routing(routes: [Route(inputs: "1", outputs: "1", gainDB: -200)], inputs: 1, outputs: 1))
        render(core.pointer, input, output)
        XCTAssertEqual(output[0][0], 0.5 * (1 - 1 / Float(frames)), accuracy: 1e-5)
        XCTAssertEqual(output[0][frames - 1], 0, accuracy: 1e-6)
    }

    func testChannelsTheMatrixDoesNotHave() throws {
        let core = RenderCore(sampleRate: 48_000)
        core.publish(try Routing(routes: [], inputs: 4, outputs: 2))
        // Only one input buffer is given, and a third output the matrix does not have.
        let input = TestBuffers(channels: 1, frames: frames) { _, _ in 1 }
        let output = TestBuffers(channels: 3, frames: frames) { _, _ in 9 }
        render(core.pointer, input, output)
        render(core.pointer, input, output)
        XCTAssertEqual(output[0], [Float](repeating: 1, count: frames))
        XCTAssertEqual(output[1], [Float](repeating: 0, count: frames), "its input was not given")
        XCTAssertEqual(output[2], [Float](repeating: 0, count: frames), "not in the matrix")

        // A null input pointer is a silent input.
        let ins: [UnsafePointer<Float>?] = [nil]
        let outs: [UnsafeMutablePointer<Float>?] = output.channels
        feral_core_render(core.pointer, ins, 1, outs, 3, Int32(frames))
        XCTAssertEqual(output[0], [Float](repeating: 0, count: frames))
    }

    func testCollectFreesOnlyStatesTheAudioThreadHasPassed() throws {
        let core = RenderCore(sampleRate: 48_000)
        let routing = try Routing(routes: [], inputs: 2, outputs: 2)
        let input = TestBuffers(channels: 2, frames: frames)
        let output = TestBuffers(channels: 2, frames: frames)

        core.publish(routing)
        render(core.pointer, input, output) // the audio thread now uses state 1
        core.publish(routing)
        core.publish(routing)
        XCTAssertEqual(core.collect(), 0, "state 1 is in use and 2 and 3 are newer")
        XCTAssertEqual(core.liveStates, 3)

        render(core.pointer, input, output) // skips state 2 and moves to 3
        XCTAssertEqual(core.stats().currentState, 3)
        XCTAssertEqual(core.collect(), 2)
        XCTAssertEqual(core.liveStates, 1)
        XCTAssertEqual(core.collect(), 0, "the newest state is never freed")
    }

    func testDetachingFreesOldStatesAndFadesInAgain() throws {
        let core = RenderCore(sampleRate: 48_000)
        let input = TestBuffers(channels: 1, frames: frames) { _, _ in 1 }
        let output = TestBuffers(channels: 1, frames: frames)
        core.publish(try Routing(routes: [], inputs: 1, outputs: 1))
        render(core.pointer, input, output)
        render(core.pointer, input, output)
        // The device stops; meanwhile the routing changes a few times.
        core.audioDetached()
        for _ in 0..<5 { core.publish(try Routing(routes: [], inputs: 1, outputs: 1)) }
        core.audioDetached()
        XCTAssertEqual(core.collect(), 5)
        XCTAssertEqual(core.liveStates, 1)
        // On restart the first buffer fades in, so the device does not start with a click.
        render(core.pointer, input, output)
        XCTAssertEqual(output[0][0], 1 / Float(frames), accuracy: 1e-6)
        XCTAssertEqual(output[0][frames - 1], 1, accuracy: 1e-6)
    }

    func testStats() throws {
        let core = RenderCore(sampleRate: 48_000)
        core.publish(try Routing(routes: [], inputs: 8, outputs: 8))
        let input = TestBuffers(channels: 8, frames: frames)
        let output = TestBuffers(channels: 8, frames: frames)
        for _ in 0..<10 { render(core.pointer, input, output) }
        let s = core.stats(resetMaxLoad: true)
        XCTAssertEqual(s.buffers, 10)
        XCTAssertEqual(s.stateSwaps, 1)
        XCTAssertEqual(s.currentState, 1)
        XCTAssertGreaterThan(s.maxLoad, 0)
        XCTAssertEqual(core.stats().maxLoad, 0, "reset")
    }

    /// The control thread publishes as fast as it can while the audio thread renders and a third
    /// thread frees old states. Every output sample must come from a whole state (gain 0.5 or 1,
    /// or a ramp between them), never a torn or freed one. Run under the thread sanitizer in CI.
    func testPublishingWhileRendering() throws {
        let core = RenderCore(sampleRate: 48_000)
        let half = try Routing(routes: [Route(inputs: "1-8", outputs: "1-8", gainDB: -6.0206)], inputs: 8, outputs: 8)
        let full = try Routing(routes: [], inputs: 8, outputs: 8)
        core.publish(full)
        let input = TestBuffers(channels: 8, frames: 32) { _, _ in 1 }
        let output = TestBuffers(channels: 8, frames: 32)
        render(core.pointer, input, output) // the fade-in

        let publishes = 20_000
        let done = DispatchGroup()
        let stop = ManagedAtomicFlag()
        done.enter()
        Thread.detachNewThread {
            for k in 0..<publishes { core.publish(k % 2 == 0 ? half : full) }
            stop.set()
            done.leave()
        }
        done.enter()
        Thread.detachNewThread {
            while !stop.isSet { core.collect() }
            done.leave()
        }
        var bad = 0
        var buffers = 0
        while !stop.isSet || buffers < 100 {
            render(core.pointer, input, output)
            buffers += 1
            for c in 0..<8 { for v in output[c] where v < 0.5 - 1e-5 || v > 1 + 1e-5 { bad += 1 } }
        }
        done.wait()
        render(core.pointer, input, output)
        core.collect()
        XCTAssertEqual(bad, 0)
        XCTAssertEqual(core.liveStates, 1)
        XCTAssertEqual(core.stats().currentState, UInt64(publishes + 1))
    }

    /// 128 by 128 at a 64-frame buffer must use a small share of the buffer's 1.33 ms, even with
    /// every input routed to every output (16,384 gains, far more than a real show's matrix).
    func testFullMatrixFitsTheBuffer() throws {
        #if DEBUG
        throw XCTSkip("timing is only meaningful in a release build (swift test -c release)")
        #else
        let core = RenderCore(sampleRate: 48_000)
        let dense = try Routing(routes: (1...128).map { Route(inputs: "1-128", outputs: String($0), gainDB: -42) },
                                inputs: 128, outputs: 128)
        core.publish(dense)
        let input = TestBuffers(channels: 128, frames: 64, fill: signal)
        let output = TestBuffers(channels: 128, frames: 64)
        for _ in 0..<2000 { render(core.pointer, input, output) }
        let s = core.stats()
        XCTAssertEqual(s.buffers, 2000)
        let started = Date()
        for _ in 0..<2000 { render(core.pointer, input, output) }
        let average = Date().timeIntervalSince(started) / 2000
        print("128 x 128 dense, 64 frames: \(String(format: "%.1f", average * 1e6)) µs per buffer of 1333 µs")
        XCTAssertLessThan(average, 0.5 * 64 / 48_000)
        #endif
    }
}

/// A flag one thread sets and another polls.
final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

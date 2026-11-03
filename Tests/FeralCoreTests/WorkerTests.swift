import FeralCore
import FeralScene
import XCTest

/// Render workers share the outputs with the audio thread; the result must not change at all.
final class WorkerTests: XCTestCase {
    func testWorkersRenderExactlyWhatOneThreadDoes() throws {
        let inputs = 16, outputs = 40, frames = 128
        let single = RenderCore(sampleRate: 48_000), shared = RenderCore(sampleRate: 48_000)
        XCTAssertEqual(shared.startWorkers(3), 3)
        XCTAssertEqual(shared.workers, 3)
        XCTAssertEqual(single.workers, 0)
        func state(_ shift: Double) -> RenderState {
            let s = RenderState(inputs: inputs, outputs: outputs)
            for o in 0..<outputs {
                for i in 0..<inputs { s.addDelay(input: i, output: o, gain: 0.05, delay: 20 + Double((i * 7 + o * 13) % 50) * 3.3 + shift) }
            }
            return s
        }
        for core in [single, shared] { try core.publish(state(0)) }
        var seed: UInt32 = 1
        func noise() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) - 0.5 }
        for block in 0..<300 {
            if block == 100 { for core in [single, shared] { try core.publish(state(2.5)) } } // delays move
            let input = TestBuffers(channels: inputs, frames: frames) { _, _ in noise() }
            let a = TestBuffers(channels: outputs, frames: frames), b = TestBuffers(channels: outputs, frames: frames)
            render(single.pointer, input, a)
            render(shared.pointer, input, b)
            for o in 0..<outputs { XCTAssertEqual(a[o], b[o], "output \(o), block \(block)") }
            _ = single.collect()
            _ = shared.collect()
        }
        XCTAssertGreaterThanOrEqual(RenderCore.automaticWorkers, 0)
    }
}

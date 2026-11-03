import FeralCore
import FeralScene
import XCTest

/// The binaural monitor: each speaker's feed through its HRIR pair, 64 samples behind; solo and PFL.
final class MonitorTests: XCTestCase {
    /// Speakers on outputs 0 and 1 playing inputs 0 and 1; the monitor on outputs 2 and 3.
    private func core(_ speakers: [MonitorSpeaker]) throws -> RenderCore {
        let core = RenderCore(sampleRate: 48_000)
        let s = RenderState(inputs: 2, outputs: 4)
        s.addGain(input: 0, output: 0, gain: 1)
        s.addGain(input: 1, output: 1, gain: 1)
        try core.publish(s)
        core.setMonitor(left: 2, right: 3, gain: 1, speakers: speakers)
        return core
    }

    private func delta(at n: Int, _ length: Int = 4) -> [Float] {
        var h = [Float](repeating: 0, count: length)
        h[n] = 1
        return h
    }

    /// Runs `blocks` buffers of noise and returns both inputs and the two monitor outputs.
    private func run(_ core: RenderCore, blocks: Int, frames: Int = 48) -> (inputs: [[Float]], left: [Float], right: [Float]) {
        var seed: UInt32 = 7
        func noise() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) - 0.5 }
        var ins: [[Float]] = [[], []], left: [Float] = [], right: [Float] = []
        for _ in 0..<blocks {
            let input = TestBuffers(channels: 2, frames: frames) { _, _ in noise() }
            let out = TestBuffers(channels: 4, frames: frames)
            render(core.pointer, input, out)
            ins[0] += input[0]; ins[1] += input[1]
            left += out[2]; right += out[3]
            _ = core.collect()
        }
        return (ins, left, right)
    }

    func testEachEarHearsItsSpeakersThroughTheirResponses() throws {
        // Speaker 0 (input 0) to the left ear only, 3 samples late; speaker 1 to the right at half
        // level, 10 samples further away.
        let c = try core([
            MonitorSpeaker(output: 0, gain: 1, delay: 0, left: delta(at: 3), right: [0, 0, 0, 0]),
            MonitorSpeaker(output: 1, gain: 0.5, delay: 10, left: [0], right: [1]),
        ])
        let r = run(c, blocks: 40)
        // The first buffer ramps the speakers in; check after it.
        for t in 200..<r.left.count {
            XCTAssertEqual(r.left[t], r.inputs[0][t - 64 - 3], accuracy: 1e-5, "left at \(t)")
            XCTAssertEqual(r.right[t], 0.5 * r.inputs[1][t - 64 - 10], accuracy: 1e-5, "right at \(t)")
        }
    }

    func testLongResponsesSpanPartitions() throws {
        let c = try core([MonitorSpeaker(output: 0, gain: 1, delay: 0, left: delta(at: 300, 400), right: delta(at: 1, 400))])
        let r = run(c, blocks: 40)
        for t in 500..<r.left.count {
            XCTAssertEqual(r.left[t], r.inputs[0][t - 64 - 300], accuracy: 1e-5)
            XCTAssertEqual(r.right[t], r.inputs[0][t - 64 - 1], accuracy: 1e-5)
        }
    }

    func testSoloHearsOnlyTheSoloedInput() throws {
        let c = try core([
            MonitorSpeaker(output: 0, gain: 1, delay: 0, left: [1], right: [0]),
            MonitorSpeaker(output: 1, gain: 1, delay: 0, left: [1], right: [0]),
        ])
        c.setListen(input: 1, solo: true, pflLeft: 0, pflRight: 0)
        let r = run(c, blocks: 40)
        for t in 200..<r.left.count { XCTAssertEqual(r.left[t], r.inputs[1][t - 64], accuracy: 1e-5) }
        c.clearListen()
    }

    func testPFLIsStereoAndImmediate() throws {
        let c = try core([MonitorSpeaker(output: 0, gain: 1, delay: 0, left: [1], right: [1])])
        c.setListen(input: 0, solo: true, pflLeft: 1, pflRight: 0)
        c.setListen(input: 1, solo: false, pflLeft: 0, pflRight: 0.5)
        let r = run(c, blocks: 10)
        for t in 0..<r.left.count {
            XCTAssertEqual(r.left[t], r.inputs[0][t], accuracy: 1e-6)
            XCTAssertEqual(r.right[t], 0.5 * r.inputs[1][t], accuracy: 1e-6)
        }
    }

    func testOffLeavesTheOutputsAlone() throws {
        let c = try core([MonitorSpeaker(output: 0, gain: 1, delay: 0, left: [1], right: [1])])
        c.setMonitor(left: nil, right: nil, gain: 1, speakers: [])
        let r = run(c, blocks: 4)
        XCTAssertTrue(r.left.allSatisfy { $0 == 0 })
        XCTAssertTrue(r.right.allSatisfy { $0 == 0 })
    }

    func testHeadModelIsLouderAndEarlierOnTheNearSide() {
        let head = SphericalHead(sampleRate: 48_000)
        let h = head.hrir(azimuth: 90, elevation: 0) // hard left
        func energy(_ x: [Float]) -> Float { x.reduce(0) { $0 + $1 * $1 } }
        func onset(_ x: [Float]) -> Int { x.firstIndex { abs($0) > 1e-3 } ?? x.count }
        XCTAssertGreaterThan(energy(h.left), energy(h.right))
        XCTAssertLessThan(onset(h.left), onset(h.right))
        // About 0.66 ms between the ears at 90°.
        XCTAssertEqual(Double(onset(h.right) - onset(h.left)), 0.000656 * 48_000, accuracy: 3)
        let front = head.hrir(azimuth: 0, elevation: 0)
        XCTAssertEqual(front.left, front.right)
    }
}

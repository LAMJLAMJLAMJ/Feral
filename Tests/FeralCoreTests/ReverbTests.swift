import FeralCore
import FeralScene
import XCTest

/// The rooms' late tails and the early reflections, in the render core.
final class ReverbTests: XCTestCase {
    let rate = 48_000.0

    /// A room on `outputs` outputs fed by input 0, every line on every output with Hadamard signs.
    func roomState(outputs: Int, decay: Double, modulation: Double = 0.5) -> RenderState {
        let s = RenderState(inputs: 1, outputs: outputs)
        var p = RoomParams(sampleRate: rate)
        p.on = true
        p.decay = (decay, decay, decay)
        p.lineLength = 0.03 * rate
        p.modulation = modulation
        s.setRoom(0, p)
        s.addRoomSend(input: 0, room: 0, gain: 1)
        let level = Float(1 / Double(outputs).squareRoot())
        for o in 0..<outputs {
            for line in 0..<Int(FERAL_ROOM_LINES) {
                s.addRoomOutput(room: 0, line: line, output: o, gain: ImageSources.tailSign(speaker: o, line: line) ? -level : level)
            }
        }
        return s
    }

    /// Renders an impulse (in the second buffer, once the send has ramped up) for `seconds`.
    func impulse(_ core: RenderCore, outputs: Int, seconds: Double, frames: Int = 64) -> [[Float]] {
        var result = [[Float]](repeating: [], count: outputs)
        let blocks = Int(seconds * rate) / frames
        for b in 0..<blocks {
            let input = TestBuffers(channels: 1, frames: frames) { _, n in b == 1 && n == 0 ? 1 : 0 }
            let out = TestBuffers(channels: outputs, frames: frames)
            render(core.pointer, input, out)
            for o in 0..<outputs { result[o] += out[o] }
        }
        return result
    }

    /// The decay time from the Schroeder integral's -5 to -35 dB (T30, doubled).
    func rt60(_ y: [[Float]]) -> (rt: Double, energy: Double) {
        let n = y[0].count
        var e = [Double](repeating: 0, count: n)
        for ch in y { for k in 0..<n { e[k] += Double(ch[k]) * Double(ch[k]) } }
        let total = e.reduce(0, +)
        var rest = total
        var t5 = -1, t35 = -1
        for k in 0..<n {
            rest -= e[k]
            let db = 10 * log10(max(rest, 1e-30) / total)
            if t5 < 0 && db < -5 { t5 = k }
            if t35 < 0 && db < -35 { t35 = k; break }
        }
        return (2 * Double(t35 - t5) / rate, total)
    }

    func testTheTailDecaysAtItsRT60AndKeepsItsEnergy() throws {
        for decay in [0.5, 2.0, 8.0] {
            let core = RenderCore(sampleRate: rate)
            try core.publish(roomState(outputs: 4, decay: decay))
            let y = impulse(core, outputs: 4, seconds: decay * 1.5 + 0.5)
            let (rt, energy) = rt60(y)
            XCTAssertEqual(rt, decay, accuracy: decay * 0.08, "decay \(decay) s")
            XCTAssertEqual(energy, 1, accuracy: 0.15, "the tail holds the send's energy (decay \(decay) s)")
        }
    }

    func testTheTailIsDecorrelatedAcrossSpeakers() throws {
        let core = RenderCore(sampleRate: rate)
        try core.publish(roomState(outputs: 20, decay: 1.5))
        let y = impulse(core, outputs: 20, seconds: 2)
        for (a, b) in [(0, 1), (3, 7), (0, 16), (5, 19)] {
            var ab = 0.0, aa = 0.0, bb = 0.0
            for k in y[a].indices {
                ab += Double(y[a][k]) * Double(y[b][k]); aa += Double(y[a][k] * y[a][k]); bb += Double(y[b][k] * y[b][k])
            }
            XCTAssertLessThan(abs(ab / (aa * bb).squareRoot()), 0.15, "outputs \(a) and \(b)")
        }
    }

    func testTheTailNeverComesBeforeTheDirectSound() throws {
        let core = RenderCore(sampleRate: rate)
        let s = roomState(outputs: 2, decay: 1)
        s.addGain(input: 0, output: 0, gain: 1)
        try core.publish(s)
        let y = impulse(core, outputs: 2, seconds: 0.2)
        XCTAssertEqual(y[0][64], 1, accuracy: 1e-6, "the direct sound is not delayed")
        XCTAssertEqual(y[1][..<(64 + 200)].map { abs($0) }.max(), 0, "the tail starts after the lines' shortest length")
    }

    func testAReflectionPlaysAtItsDelayGainAndOutputs() throws {
        let core = RenderCore(sampleRate: rate)
        let s = RenderState(inputs: 1, outputs: 3)
        s.setReflections(input: 0, delays: [480, 960.5], gains: [0.5, 0.25], filter: [])
        s.addReflectionOutput(input: 0, reflection: 0, output: 1, gain: 1)
        s.addReflectionOutput(input: 0, reflection: 1, output: 2, gain: 0.8)
        s.addReflectionOutput(input: 0, reflection: 1, output: 1, gain: 0.6)
        try core.publish(s)
        let y = impulse(core, outputs: 3, seconds: 0.1)
        XCTAssertEqual(y[0].map { abs($0) }.max(), 0, "output 0 has no reflection")
        XCTAssertEqual(y[1][64 + 480], 0.5, accuracy: 1e-6)
        XCTAssertEqual(y[1][64 + 479], 0, accuracy: 1e-6)
        // The fractional delay spreads the second one over its neighbours.
        let around = (64 + 958)...(64 + 963)
        XCTAssertEqual(around.map { Double(y[2][$0]) }.reduce(0, +), 0.25 * 0.8, accuracy: 0.01)
        XCTAssertEqual(around.map { Double(y[1][$0]) }.reduce(0, +), 0.25 * 0.6, accuracy: 0.01)
    }

    func testRemovedReflectionsFadeOutAndAMutedRoomFallsSilent() throws {
        let core = RenderCore(sampleRate: rate)
        let s = roomState(outputs: 2, decay: 1)
        s.setReflections(input: 0, delays: [100], gains: [1], filter: [])
        s.addReflectionOutput(input: 0, reflection: 0, output: 0, gain: 1)
        try core.publish(s)
        _ = impulse(core, outputs: 2, seconds: 0.3)
        try core.publish(RenderState(inputs: 1, outputs: 2)) // no room, no reflections
        let quiet = TestBuffers(channels: 1, frames: 64) { _, n in Float(n % 7) * 0.1 }
        let out = TestBuffers(channels: 2, frames: 64)
        render(core.pointer, quiet, out)
        render(core.pointer, quiet, out)
        XCTAssertEqual(out[0].map { abs($0) }.max(), 0, "silent a buffer after")
        XCTAssertEqual(out[1].map { abs($0) }.max(), 0)
    }

    /// The reverb shares its work with the render workers; the result must not change at all.
    func testWorkersRenderTheReverbExactlyAsOneThreadDoes() throws {
        let inputs = 24, outputs = 30, frames = 64
        let single = RenderCore(sampleRate: rate), shared = RenderCore(sampleRate: rate)
        XCTAssertEqual(shared.startWorkers(3), 3)
        func state(_ shift: Double) -> RenderState {
            let s = RenderState(inputs: inputs, outputs: outputs)
            for r in 0..<2 {
                var p = RoomParams(sampleRate: rate)
                p.on = true
                p.decay = (1.5, 1 + Double(r), 0.5)
                p.predelay = 100 * shift
                s.setRoom(r, p)
                for o in 0..<outputs {
                    for line in 0..<Int(FERAL_ROOM_LINES) where (o + line + r) % 3 == 0 {
                        s.addRoomOutput(room: r, line: line, output: o, gain: 0.1)
                    }
                }
            }
            for i in 0..<inputs {
                s.addGain(input: i, output: i % outputs, gain: 0.5)
                s.addRoomSend(input: i, room: i % 2, gain: 0.3)
                let n = 1 + i % 16
                s.setReflections(input: i, delays: (0..<n).map { 50 + Double($0) * 37.3 + shift }, gains: (0..<n).map { _ in 0.2 },
                                 filter: [Biquad(EQBand(.lowPass, hz: 6000), sampleRate: rate)])
                for k in 0..<n { s.addReflectionOutput(input: i, reflection: k, output: (i * 5 + k * 3) % outputs, gain: 0.7) }
            }
            return s
        }
        for core in [single, shared] { try core.publish(state(0)) }
        var seed: UInt32 = 7
        func noise() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) - 0.5 }
        for block in 0..<400 {
            if block == 150 { for core in [single, shared] { try core.publish(state(3.5)) } }
            let input = TestBuffers(channels: inputs, frames: frames) { _, _ in noise() }
            let a = TestBuffers(channels: outputs, frames: frames), b = TestBuffers(channels: outputs, frames: frames)
            render(single.pointer, input, a)
            render(shared.pointer, input, b)
            for o in 0..<outputs { XCTAssertEqual(a[o], b[o], "output \(o), block \(block)") }
            _ = single.collect()
            _ = shared.collect()
        }
    }
}

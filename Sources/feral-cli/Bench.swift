import FeralCore
import FeralScene
import Foundation

/// Times the render core on this Mac at the design's size, 128 sources by 128 speakers at 48 kHz in
/// 64-frame buffers: every source on 3 speakers, then the same with the reverb at its heaviest (two
/// rooms on every speaker, every source sending to one and 16 early reflections on 3 speakers each),
/// on the audio thread alone and with the render workers the engine would start.
func runBench() {
    let rate = 48_000.0, frames = 64, inputs = 128, outputs = 128
    func state(reverb: Bool) -> RenderState {
        let s = RenderState(inputs: inputs, outputs: outputs)
        for i in 0..<inputs {
            for k in 0..<3 { s.addGain(input: i, output: (i + k * 41) % outputs, gain: 0.3) }
            guard reverb else { continue }
            s.addRoomSend(input: i, room: i % 2, gain: 0.3)
            let n = Int(FERAL_MAX_REFLECTIONS)
            s.setReflections(input: i, delays: (0..<n).map { 200 + Double(($0 * 977 + i * 131) % 4000) + 0.37 },
                             gains: Array(repeating: 0.1, count: n), filter: [Biquad(EQBand(.lowPass, hz: 8000), sampleRate: rate)])
            for k in 0..<n {
                for t in 0..<3 { s.addReflectionOutput(input: i, reflection: k, output: (i * 7 + k * 13 + t * 31) % outputs, gain: 0.5) }
            }
        }
        if reverb {
            for r in 0..<2 {
                var p = RoomParams(sampleRate: rate)
                p.on = true
                p.decay = (9, 8, 4)
                s.setRoom(r, p)
                for o in 0..<outputs {
                    for line in 0..<Int(FERAL_ROOM_LINES) {
                        s.addRoomOutput(room: r, line: line, output: o, gain: ImageSources.tailSign(speaker: o, line: line) ? -0.09 : 0.09)
                    }
                }
            }
        }
        return s
    }
    let input = (0..<inputs).map { c -> UnsafeMutablePointer<Float> in
        let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        var seed = UInt32(c + 1)
        for n in 0..<frames { seed = seed &* 1_664_525 &+ 1_013_904_223; p[n] = Float(seed >> 8) / Float(1 << 24) * 0.1 - 0.05 }
        return p
    }
    let output = (0..<outputs).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
    let ins: [UnsafePointer<Float>?] = input.map { UnsafePointer($0) }
    let outs: [UnsafeMutablePointer<Float>?] = output
    let budget = Double(frames) / rate
    print("128 inputs x 128 outputs, 48 kHz, 64-frame buffers (\(String(format: "%.0f", budget * 1e6)) µs each):")
    for workers in [0, RenderCore.automaticWorkers] {
        for reverb in [false, true] {
            let core = RenderCore(sampleRate: rate)
            core.startWorkers(workers)
            do { try core.publish(state(reverb: reverb)) } catch { fail("\(error)") }
            for _ in 0..<500 { feral_core_render(core.pointer, ins, Int32(inputs), outs, Int32(outputs), Int32(frames)) }
            let count = 5000
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<count { feral_core_render(core.pointer, ins, Int32(inputs), outs, Int32(outputs), Int32(frames)) }
            let each = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 / Double(count)
            let what = reverb ? "with reverb (2 rooms, 16 reflections a source)" : "direct sound only"
            print("  \(workers == 0 ? "audio thread alone" : "with \(workers) workers"), \(what): "
                  + String(format: "%.0f µs, %.1f %% of the buffer", each * 1e6, each / budget * 100))
            _ = core.collect()
        }
    }
    input.forEach { $0.deallocate() }
    output.forEach { $0.deallocate() }
    exit(0)
}

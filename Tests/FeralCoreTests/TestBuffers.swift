import FeralCore

/// Channel buffers to render through the core, as the C API wants them (arrays of channel pointers).
final class TestBuffers {
    let channels: [UnsafeMutablePointer<Float>]
    let frames: Int

    init(channels: Int, frames: Int, fill: (Int, Int) -> Float = { _, _ in 0 }) {
        self.frames = frames
        self.channels = (0..<channels).map { c in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            for n in 0..<frames { p[n] = fill(c, n) }
            return p
        }
    }

    deinit { channels.forEach { $0.deallocate() } }

    subscript(channel: Int) -> [Float] { Array(UnsafeBufferPointer(start: channels[channel], count: frames)) }
}

/// Renders one buffer of inputs into outputs.
func render(_ core: OpaquePointer, _ inputs: TestBuffers, _ outputs: TestBuffers) {
    let ins: [UnsafePointer<Float>?] = inputs.channels.map { UnsafePointer($0) }
    let outs: [UnsafeMutablePointer<Float>?] = outputs.channels
    feral_core_render(core, ins, Int32(ins.count), outs, Int32(outs.count), Int32(outputs.frames))
}

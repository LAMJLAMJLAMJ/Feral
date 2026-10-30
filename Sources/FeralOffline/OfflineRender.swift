import FeralCore
import FeralScene
import Foundation

/// Renders audio through the same render core the engine uses, faster than real time, for tests
/// and checks (feral-cli). Buffers are the engine's size, so ramps and glides behave as they do live.
public final class OfflineRenderer {
    public let config: EngineConfig
    public let core: RenderCore
    public let spatial: SpatialRenderer?
    private var inputs: [UnsafeMutablePointer<Float>]
    private var outputs: [UnsafeMutablePointer<Float>]
    private let frames: Int

    /// Publishes the config's layout (or routing) and test signal, then renders one silent buffer so
    /// the start-up fade-in is over before the first sample that counts.
    public init(config: EngineConfig) throws {
        try config.validate()
        self.config = config
        frames = config.bufferFrames
        core = RenderCore(sampleRate: config.sampleRate)
        if config.isSpatial {
            let s = try SpatialRenderer(config: config)
            try core.publish(s.makeState())
            spatial = s
        } else {
            core.publish(try Routing(routes: config.routes, inputs: config.inputs, outputs: config.outputs))
            spatial = nil
        }
        core.setTestSignal(config.testSignal, levelDB: config.testSignalDB, sineHz: config.testSignalHz)
        inputs = (0..<config.inputs).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: config.bufferFrames) }
        outputs = (0..<config.outputs).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: config.bufferFrames) }
        for p in inputs { p.initialize(repeating: 0, count: frames) }
        renderBuffer()
    }

    deinit {
        inputs.forEach { $0.deallocate() }
        outputs.forEach { $0.deallocate() }
    }

    private func renderBuffer() {
        let ins: [UnsafePointer<Float>?] = inputs.map { UnsafePointer($0) }
        let outs: [UnsafeMutablePointer<Float>?] = outputs
        feral_core_render(core.pointer, ins, Int32(ins.count), outs, Int32(outs.count), Int32(frames))
    }

    /// Renders `length` samples. `input[c]` is engine input c (from 0); missing inputs and samples
    /// are silent. Returns one array per engine output. The config's test
    /// motion, if any, moves its source every 20 ms as the engine does.
    public func render(length: Int, input: [[Float]]) -> [[Float]] {
        var result = [[Float]](repeating: [Float](repeating: 0, count: length), count: config.outputs)
        let motionIndex = config.testMotion.flatMap { m in spatial?.sourceIndex(input: m.source) }
        let motionEvery = max(1, Int((0.02 * config.sampleRate / Double(frames)).rounded()))
        var buffer = 0
        var start = 0
        while start < length {
            let n = min(frames, length - start)
            for (c, p) in inputs.enumerated() {
                for k in 0..<frames {
                    p[k] = c < input.count && k < n && start + k < input[c].count ? input[c][start + k] : 0
                }
            }
            if let motion = config.testMotion, let index = motionIndex, let spatial, buffer % motionEvery == 0 {
                spatial.move(source: index, to: motion.position(at: Double(start) / config.sampleRate))
                try? core.publish(spatial.makeState())
                core.collect()
            }
            renderBuffer()
            for c in 0..<config.outputs { for k in 0..<n { result[c][start + k] = outputs[c][k] } }
            start += n
            buffer += 1
        }
        core.collect()
        return result
    }

    /// Where an impulse on one input arrives at each output: the loudest sample's time and level.
    public struct Arrival: Equatable {
        /// Engine output, from 1.
        public var output: Int
        public var milliseconds: Double
        public var levelDB: Double
        /// True when the loudest sample is negative (polarity flipped).
        public var inverted: Bool
    }

    /// Plays a unit impulse into `input` (from 1) and measures every output it reaches.
    public func impulse(input: Int, seconds: Double = 1.2) -> [Arrival] {
        let length = Int(seconds * config.sampleRate)
        var x = [[Float]](repeating: [], count: config.inputs)
        x[input - 1] = [1] + [Float](repeating: 0, count: length - 1)
        let y = render(length: length, input: x)
        var result: [Arrival] = []
        for (o, channel) in y.enumerated() {
            guard let peak = channel.indices.max(by: { abs(channel[$0]) < abs(channel[$1]) }), abs(channel[peak]) > 1e-6 else { continue }
            result.append(Arrival(output: o + 1, milliseconds: Double(peak) / config.sampleRate * 1000,
                                  levelDB: 20 * log10(Double(abs(channel[peak]))), inverted: channel[peak] < 0))
        }
        return result
    }
}

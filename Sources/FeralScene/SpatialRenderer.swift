import FeralCore
import Foundation

/// Turns the spatial settings (speakers, groups, sources) into render states. It keeps every
/// source's taps, so moving one source recomputes only that source's gains and delays.
public final class SpatialRenderer {
    /// One speaker feed of one source.
    public struct Tap: Equatable {
        /// Engine output, from 0.
        public var output: Int
        /// The group's name, or "LFE".
        public var group: String
        /// Through the source's delay line (Delay groups), or straight.
        public var delayed: Bool
        /// Linear, with the source's, the send's and the group's gain in it.
        public var gain: Float
        /// Seconds (Delay groups; 0 for the others).
        public var delay: Double
    }

    public let config: EngineConfig
    public let sampleRate: Double
    public let motion: DelayMotion
    private let groups: [Group]
    private let lfeOutputs: [Int]
    private let routing: Routing?
    private let outputParams: [Int: OutputParams]
    public private(set) var positions: [Position]
    private var taps: [[Tap]]

    private final class Group {
        let config: GroupConfig
        let outputs: [Int] // from 0
        let points: [feral_point]
        let weights: [Double]
        let vbap: OpaquePointer?
        let gain: Double

        init(_ config: GroupConfig, speakers: [SpeakerConfig], outputs: [Int]) throws {
            let points = speakers.map { $0.position.c }
            self.config = config
            self.outputs = outputs
            self.points = points
            weights = speakers.map { pow(10, (config.weightsDB[String($0.output)] ?? 0) / 20) }
            gain = pow(10, config.gainDB / 20)
            if config.renderer == .vbap {
                let reference = (config.reference ?? Group.defaultReference(speakers)).c
                let dims = Int32(config.dimensions ?? 0)
                guard let v = points.withUnsafeBufferPointer({ feral_vbap_create($0.baseAddress, Int32($0.count), reference, dims) }) else {
                    throw ConfigError("group \(config.name): VBAP needs at least 2 speakers, and in 3D speakers around the reference on more than one side")
                }
                vbap = v
            } else {
                vbap = nil
            }
        }

        deinit { if let vbap { feral_vbap_destroy(vbap) } }

        /// The speakers' centre in plan, at ear height.
        static func defaultReference(_ speakers: [SpeakerConfig]) -> Position {
            let n = Double(max(speakers.count, 1))
            return Position(speakers.map(\.position.x).reduce(0, +) / n, speakers.map(\.position.y).reduce(0, +) / n, 1.2)
        }

        var summary: String {
            var s = "\(config.name): \(config.renderer.rawValue), \(outputs.count) speaker(s)"
            if let vbap {
                s += ", \(feral_vbap_dimensions(vbap))D, \(feral_vbap_regions(vbap)) "
                    + (feral_vbap_dimensions(vbap) == 2 ? "pair(s)" : "triangle(s)")
                let extra = feral_vbap_virtual_speakers(vbap)
                if extra > 0 { s += ", \(extra) virtual speaker(s) closing the dome" }
            }
            return s
        }
    }

    /// Builds the groups (VBAP triangulations) and every source's taps. The config must have been
    /// validated (EngineConfig.validate).
    public init(config: EngineConfig) throws {
        self.config = config
        sampleRate = config.sampleRate
        motion = config.delayMotion
        groups = try config.groups.map { g in
            let outs = try Routing.channelList(g.speakers, limit: config.outputs, side: "output")
            let speakers = try outs.map { o -> SpeakerConfig in
                guard let s = config.speakers.first(where: { $0.output == o }) else {
                    throw ConfigError("group \(g.name): output \(o) has no speaker")
                }
                return s
            }
            return try Group(g, speakers: speakers, outputs: outs.map { $0 - 1 })
        }
        lfeOutputs = try config.lfeOutputs.map { try Routing.channelList($0, limit: config.outputs, side: "output").map { $0 - 1 } } ?? []
        routing = try config.routes.isEmpty ? nil : Routing(routes: config.routes, inputs: config.inputs, outputs: config.outputs)
        var params: [Int: OutputParams] = [:]
        for s in config.speakers { params[s.output - 1] = SpatialRenderer.outputParams(s, sampleRate: config.sampleRate) }
        outputParams = params
        positions = config.sources.map(\.position)
        taps = Array(repeating: [], count: config.sources.count)
        for i in config.sources.indices { taps[i] = computeTaps(source: i) }
    }

    /// One line per group, for the log.
    public var groupSummaries: [String] { groups.map(\.summary) }

    /// Taps of every source, in source order.
    public var allTaps: [[Tap]] { taps }

    /// Moves a source (by its index in config.sources) and recomputes its taps.
    public func move(source index: Int, to position: Position) {
        positions[index] = position
        taps[index] = computeTaps(source: index)
    }

    /// The index in config.sources of the source on an input (from 1).
    public func sourceIndex(input: Int) -> Int? { config.sources.firstIndex { $0.input == input } }

    /// The render state for the sources where they are now, plus any fixed routes, the speakers'
    /// processing and the delay motion.
    public func makeState() -> RenderState {
        let state = RenderState(inputs: config.inputs, outputs: config.outputs)
        state.setMotion(motion)
        for (i, source) in config.sources.enumerated() {
            let input = source.input - 1
            for t in taps[i] {
                if t.delayed {
                    state.addDelay(input: input, output: t.output, gain: t.gain, delay: t.delay * sampleRate)
                } else {
                    state.addGain(input: input, output: t.output, gain: t.gain)
                }
            }
        }
        if let routing {
            for o in 0..<routing.outputs {
                for i in 0..<routing.inputs {
                    let g = routing.gains[o * routing.inputs + i]
                    if g != 0 { state.addGain(input: i, output: o, gain: g) }
                }
            }
        }
        for (o, p) in outputParams { state.setOutput(o, p) }
        return state
    }

    private func computeTaps(source index: Int) -> [Tap] {
        let source = config.sources[index]
        if source.mute { return [] }
        let p = positions[index].c
        let sourceGain = pow(10, source.gainDB / 20)
        var result: [Tap] = []
        for g in groups {
            let sendDB: Double
            if let sends = source.groups {
                guard let s = sends[g.config.name] else { continue }
                sendDB = s
            } else {
                sendDB = 0
            }
            let scale = sourceGain * pow(10, sendDB / 20) * g.gain
            let n = g.points.count
            var gains = [Float](repeating: 0, count: n)
            var delays = [Double](repeating: 0, count: n)
            switch g.config.renderer {
            case .delay:
                var params = feral_delay_params(
                    speed_of_sound: feral_speed_of_sound(config.airTemperatureC),
                    precedence: g.config.precedenceMS / 1000, rolloff: g.config.rolloff,
                    reference_distance: g.config.referenceDistance ?? 0, distance_offset: g.config.distanceOffset ?? -1)
                feral_delay_render(g.points, g.weights, Int32(n), p, &params, &gains, &delays)
            case .dbap:
                feral_dbap_render(g.points, g.weights, Int32(n), p, g.config.blur, g.config.rolloffDB, &gains)
            case .vbap:
                feral_vbap_render(g.vbap, p, source.width, g.config.rolloff, g.config.referenceDistance ?? 0, &gains)
                for k in 0..<n { gains[k] *= Float(g.weights[k]) }
            }
            for k in 0..<n where gains[k] != 0 {
                result.append(Tap(output: g.outputs[k], group: g.config.name, delayed: g.config.renderer == .delay,
                                  gain: gains[k] * Float(scale), delay: delays[k]))
            }
        }
        if let lfe = source.lfeDB {
            let g = Float(sourceGain * pow(10, lfe / 20))
            for o in lfeOutputs { result.append(Tap(output: o, group: "LFE", delayed: false, gain: g, delay: 0)) }
        }
        return result
    }

    /// A speaker's system-layer settings as output processing.
    public static func outputParams(_ s: SpeakerConfig, sampleRate: Double) -> OutputParams {
        var p = OutputParams()
        p.delay = s.delayMS / 1000 * sampleRate
        p.eq = s.eq.map { Biquad($0, sampleRate: sampleRate) }
        p.gain = Float(pow(10, s.trimDB / 20)) * (s.invert ? -1 : 1)
        p.limiterThreshold = s.limiterDB.map { Float(pow(10, $0 / 20)) } ?? 0
        p.limiterRelease = Float(s.limiterReleaseMS / 1000 * sampleRate)
        p.mute = s.mute
        return p
    }
}

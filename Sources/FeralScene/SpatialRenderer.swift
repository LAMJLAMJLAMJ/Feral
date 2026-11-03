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
    /// The sources as they are now (config.sources with every move and update since).
    public private(set) var sources: [SourceConfig]
    public var positions: [Position] { sources.map(\.position) }
    private var taps: [[Tap]]
    private let rooms: [RoomRender]
    /// Per source, what it plays into its room (none when it has no reverb).
    private var reverbs: [SourceReverbTaps?]

    /// A source's send to its room and its early reflections, panned.
    public struct SourceReverbTaps: Equatable {
        /// The room's index in config.rooms.
        public var room: Int
        /// Linear.
        public var send: Float
        public var reflections: [ReflectionTaps]
    }

    public struct ReflectionTaps: Equatable {
        /// Seconds after the source's earliest speaker feed.
        public var delay: Double
        /// Linear, before panning.
        public var gain: Float
        /// Engine outputs (from 0) and panning gains.
        public var outputs: [(output: Int, gain: Float)]
        public var image: Position

        public static func == (a: ReflectionTaps, b: ReflectionTaps) -> Bool {
            a.delay == b.delay && a.gain == b.gain && a.image == b.image && a.outputs.map(\.output) == b.outputs.map(\.output)
                && a.outputs.map(\.gain) == b.outputs.map(\.gain)
        }
    }

    /// A room's speakers and how reflections pan over them.
    private final class RoomRender {
        let config: RoomConfig
        let outputs: [Int] // from 0
        let points: [feral_point]
        let vbap: OpaquePointer?
        let filter: [Biquad]

        init(_ config: RoomConfig, speakers: [SpeakerConfig], sampleRate: Double) {
            self.config = config
            let placed = config.speakers.compactMap { o in speakers.first { $0.output == o } }
            outputs = placed.map { $0.output - 1 }
            points = placed.map { $0.position.c }
            vbap = points.count >= 2
                ? points.withUnsafeBufferPointer { feral_vbap_create($0.baseAddress, Int32($0.count), config.listener.c, 0) }
                : nil
            filter = config.wallFilter(sampleRate: sampleRate)
        }

        deinit { if let vbap { feral_vbap_destroy(vbap) } }

        /// Panning gains for a direction from the listener: VBAP over the room's speakers, or (when
        /// they cannot be triangulated) DBAP.
        func pan(_ p: Position) -> [Float] {
            var gains = [Float](repeating: 0, count: points.count)
            guard !points.isEmpty else { return gains }
            if let vbap {
                feral_vbap_render(vbap, p.c, 0, 0, 0, &gains)
            } else {
                feral_dbap_render(points, nil, Int32(points.count), p.c, 0.5, 6, 0, &gains)
            }
            return gains
        }
    }

    private final class Group {
        let config: GroupConfig
        let outputs: [Int] // from 0
        let points: [feral_point]
        let weights: [Double]
        let vbap: OpaquePointer?
        let gain: Double
        /// KNN and SPCAP.
        let pan: feral_pan_params
        /// What spread turns sources around: the group's reference, else the speakers' centre.
        let centre: Position

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
            centre = config.reference ?? Group.defaultReference(speakers)
            pan = feral_pan_params(reference: (config.reference ?? Group.defaultReference(speakers)).c,
                                   planar: config.dimensions == 2 ? 1 : 0, rolloff: config.rolloff,
                                   reference_distance: config.referenceDistance ?? 0, neighbours: Int32(max(1, config.neighbours)),
                                   spread: config.spread, tightness: config.tightness)
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
        sources = config.sources
        rooms = config.rooms.map { RoomRender($0, speakers: config.speakers, sampleRate: config.sampleRate) }
        taps = Array(repeating: [], count: config.sources.count)
        reverbs = Array(repeating: nil, count: config.sources.count)
        for i in config.sources.indices {
            taps[i] = computeTaps(source: i)
            reverbs[i] = computeReverb(source: i)
        }
    }

    /// Every source's reverb, in source order.
    public var allReverbs: [SourceReverbTaps?] { reverbs }

    /// One line per group, for the log.
    public var groupSummaries: [String] { groups.map(\.summary) }

    /// Taps of every source, in source order.
    public var allTaps: [[Tap]] { taps }

    /// Moves a source (by its index in config.sources) and recomputes its taps.
    public func move(source index: Int, to position: Position) {
        sources[index].position = position
        taps[index] = computeTaps(source: index)
        reverbs[index] = computeReverb(source: index)
    }

    /// Replaces a source's settings (position, gain, mute, width, sends, LFE send) and recomputes its
    /// taps. Its input stays the one it had; a new input needs a new renderer. Sends must name groups
    /// that exist.
    public func update(source index: Int, to source: SourceConfig) {
        var s = source
        s.input = sources[index].input
        sources[index] = s
        taps[index] = computeTaps(source: index)
        reverbs[index] = computeReverb(source: index)
    }

    /// The index in config.sources of the source on an input (from 1).
    public func sourceIndex(input: Int) -> Int? { sources.firstIndex { $0.input == input } }

    /// The render state for the sources where they are now, plus any fixed routes, the speakers'
    /// processing and the delay motion.
    public func makeState() -> RenderState {
        let state = RenderState(inputs: config.inputs, outputs: config.outputs)
        state.setMotion(motion)
        for (i, source) in sources.enumerated() {
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
        let inputs = config.inputs
        for source in sources where source.input >= 1 && source.input <= inputs {
            let link = source.link.flatMap { $0 >= 1 && $0 <= inputs ? $0 - 1 : nil }
            let params = InputParams(eq: source.eq, compressor: source.compressor, link: link, sampleRate: sampleRate,
                                     trimDB: source.trimDB ?? 0, invert: source.invert ?? false, delayMS: source.delayMS ?? 0,
                                     airDB: source.airDB ?? 0)
            if !params.isPlain { state.setInput(source.input - 1, params) }
        }
        addReverb(to: state)
        return state
    }

    /// The rooms (each tail spread decorrelated over its speakers), the sources' sends and their
    /// early reflections.
    private func addReverb(to state: RenderState) {
        let c = feral_speed_of_sound(config.airTemperatureC)
        for (k, room) in rooms.enumerated() {
            let r = room.config
            let on = r.on && !room.outputs.isEmpty
            var p = RoomParams(sampleRate: sampleRate)
            p.on = on
            p.decay = (r.decayS * r.lowDecay, r.decayS, r.decayS * r.highDecay)
            p.predelay = r.predelayMS / 1000 * sampleRate
            p.lineLength = min(max(r.meanFreeTime(speedOfSound: c), Double(FERAL_ROOM_MIN_LINE)), Double(FERAL_ROOM_MAX_LINE)) * sampleRate
            p.diffusion = r.diffusion
            p.modulation = r.modulation
            state.setRoom(k, p)
            guard on else { continue }
            // Every speaker gets every line, each with its own signs, at a level that keeps the
            // tail's total power the same however many speakers play it.
            let level = Float(pow(10, r.levelDB / 20) / Double(room.outputs.count).squareRoot())
            for (i, o) in room.outputs.enumerated() {
                for line in 0..<Int(FERAL_ROOM_LINES) {
                    state.addRoomOutput(room: k, line: line, output: o, gain: ImageSources.tailSign(speaker: i, line: line) ? -level : level)
                }
            }
        }
        for (i, source) in sources.enumerated() {
            guard let rv = reverbs[i], source.input >= 1, source.input <= config.inputs else { continue }
            let input = source.input - 1
            if rv.send != 0 { state.addRoomSend(input: input, room: rv.room, gain: rv.send) }
            guard !rv.reflections.isEmpty else { continue }
            state.setReflections(input: input, delays: rv.reflections.map { $0.delay * sampleRate },
                                 gains: rv.reflections.map(\.gain), filter: rooms[rv.room].filter)
            for (k, refl) in rv.reflections.enumerated() {
                for o in refl.outputs { state.addReflectionOutput(input: input, reflection: k, output: o.output, gain: o.gain) }
            }
        }
    }

    private func computeReverb(source index: Int) -> SourceReverbTaps? {
        let source = sources[index]
        guard !source.mute, let rv = source.reverb, rooms.indices.contains(rv.room) else { return nil }
        let room = rooms[rv.room]
        guard room.config.on, !room.outputs.isEmpty else { return nil }
        var result = SourceReverbTaps(room: rv.room, send: Float(pow(10, rv.sendDB / 20)), reflections: [])
        guard let earlyDB = rv.earlyDB else { return result }
        let r = room.config
        let level = pow(10, (earlyDB + r.earlyDB) / 20)
        // Reflections come after the source's earliest speaker feed (a Delay group's feeds are late).
        let base = taps[index].filter(\.delayed).map(\.delay).min() ?? 0
        let found = ImageSources.reflections(source: source.position, listener: r.listener, low: r.low, high: r.high,
                                             absorption: r.absorption, speedOfSound: feral_speed_of_sound(config.airTemperatureC))
        for f in found {
            let gains = room.pan(f.image)
            var outs: [(output: Int, gain: Float)] = []
            for (k, g) in gains.enumerated() where abs(g) > 1e-6 { outs.append((room.outputs[k], g)) }
            guard !outs.isEmpty else { continue }
            result.reflections.append(ReflectionTaps(delay: base + f.delay, gain: Float(level * f.gain), outputs: outs, image: f.image))
        }
        return result
    }

    private func computeTaps(source index: Int) -> [Tap] {
        let source = sources[index]
        if source.mute { return [] }
        let p = source.position.c
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
            let centreRender = render(g, at: p, width: source.width)
            var gains = centreRender.0
            let delays = centreRender.1
            // Spread, for every algorithm but VBAP (which spreads by itself): the gains are the RMS of
            // nine copies of the source turned across the width around the group's centre, so the
            // total power stays as it was; a Delay group keeps the delays of the source itself.
            if source.width > 0 && g.config.renderer != .vbap {
                var power = gains.map { Double($0) * Double($0) }
                let copies = 9
                for i in 0..<copies where i != copies / 2 {
                    let turn = source.width * (Double(i) / Double(copies - 1) - 0.5)
                    let q = source.position.turned(by: turn, around: g.centre).c
                    let (more, _) = render(g, at: q, width: 0)
                    for k in 0..<n { power[k] += Double(more[k]) * Double(more[k]) }
                }
                gains = power.map { Float(($0 / Double(copies)).squareRoot()) }
            }
            // Below -120 dB a feed is rounding left over from VBAP, not a speaker that plays.
            for k in 0..<n where abs(gains[k]) > 1e-6 {
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

    /// One group's gains (with the speakers' weights) and delays for a source at `p`.
    private func render(_ g: Group, at p: feral_point, width: Double) -> ([Float], [Double]) {
        let n = g.points.count
        var gains = [Float](repeating: 0, count: n)
        var delays = [Double](repeating: 0, count: n)
        switch g.config.renderer {
        case .delay:
            var params = feral_delay_params(
                speed_of_sound: feral_speed_of_sound(config.airTemperatureC),
                precedence: g.config.precedenceMS / 1000, rolloff: g.config.rolloff,
                reference_distance: g.config.referenceDistance ?? 0, distance_offset: g.config.distanceOffset ?? -1,
                planar: g.config.dimensions == 2 ? 1 : 0)
            feral_delay_render(g.points, g.weights, Int32(n), p, &params, &gains, &delays)
        case .dbap:
            feral_dbap_render(g.points, g.weights, Int32(n), p, g.config.blur, g.config.rolloffDB,
                              g.config.dimensions == 2 ? 1 : 0, &gains)
        case .vbap:
            feral_vbap_render(g.vbap, p, width, g.config.rolloff, g.config.referenceDistance ?? 0, &gains)
            for k in 0..<n { gains[k] *= Float(g.weights[k]) }
        case .knn:
            var params = g.pan
            feral_knn_render(g.points, g.weights, Int32(n), p, &params, &gains)
        case .spcap:
            var params = g.pan
            feral_spcap_render(g.points, g.weights, Int32(n), p, &params, &gains)
        case .pan:
            gains = Self.panGains(speakers: g.points, at: p, axis: g.config.panAxis ?? Position(1, 0, 0),
                                  lawDB: g.config.panLawDB).enumerated().map { Float($0.element * g.weights[$0.offset]) }
        }
        return (gains, delays)
    }

    /// A console pan pot across a line of speakers: each speaker's and the source's position along
    /// `axis` (left to right); the source plays in the two speakers either side of it, with the pan
    /// law's level at halfway (3 dB down in each: constant power; 6: linear), and past either end in
    /// the end speaker alone.
    public static func panGains(speakers: [feral_point], at p: feral_point, axis: Position, lawDB: Double) -> [Double] {
        let n = speakers.count
        var gains = [Double](repeating: 0, count: n)
        guard n > 0 else { return gains }
        let len = max(1e-9, (axis.x * axis.x + axis.y * axis.y + axis.z * axis.z).squareRoot())
        func u(_ q: feral_point) -> Double { (q.x * axis.x + q.y * axis.y + q.z * axis.z) / len }
        let order = (0..<n).sorted { u(speakers[$0]) < u(speakers[$1]) }
        let s = u(p)
        guard n > 1, s > u(speakers[order[0]]) else { gains[order[0]] = 1; return gains }
        guard s < u(speakers[order[n - 1]]) else { gains[order[n - 1]] = 1; return gains }
        var a = 0
        while a + 2 < n && u(speakers[order[a + 1]]) <= s { a += 1 }
        let ua = u(speakers[order[a]]), ub = u(speakers[order[a + 1]])
        let t = ub > ua ? (s - ua) / (ub - ua) : 0.5
        // As consoles name them: "3 dB" is constant power (cos, sin), "6 dB" linear (cos², sin²).
        let k = lawDB / 3
        gains[order[a]] = pow(cos(t * .pi / 2), k)
        gains[order[a + 1]] = pow(sin(t * .pi / 2), k)
        return gains
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

import Foundation

/// The engine's settings, read from engine.json: one audio device, a fixed routing, and the spatial
/// layout (speakers, groups, sources). The show file takes over the layout in milestone 3.
public struct EngineConfig: Codable, Equatable {
    /// The audio device: its UID (best, from `feral-engine devices`), or part of its name.
    public var device: String?
    public var sampleRate: Double
    /// Core Audio buffer size in frames. 64 is the live target; 128 or 256 while programming.
    public var bufferFrames: Int
    /// Engine inputs and outputs (sources and speaker feeds), up to 256 each.
    public var inputs: Int
    public var outputs: Int
    /// The device channel (from 1) that engine input 1 reads from. Later inputs follow in order.
    /// Useful on devices with more than 128 channels, such as an RME MADIface XT (three MADI ports),
    /// to pick which ports the engine uses.
    public var firstInputChannel: Int
    /// The device channel (from 1) that engine output 1 plays on. Later outputs follow in order.
    public var firstOutputChannel: Int
    /// The fixed gain matrix, as routes. Empty means every input straight to the output with its
    /// number (a passthrough).
    public var routes: [Route]
    /// Refuse aggregate devices, which drift or resample between clocks. Turn off only for tests.
    public var refuseAggregateDevices: Bool
    /// A generated signal in place of input 1, for checking outputs with nothing plugged in.
    public var testSignal: TestSignal
    /// The test signal's RMS level in dB re full scale (a sine's peak is 3 dB higher).
    public var testSignalDB: Double
    /// The sine's frequency.
    public var testSignalHz: Double

    // The spatial layout (see SpatialConfig.swift). With groups set, sources are rendered to the
    // speakers and `routes` only adds fixed feeds on top (no passthrough).
    public var speakers: [SpeakerConfig]
    public var groups: [GroupConfig]
    public var sources: [SourceConfig]
    /// The outputs a source's LFE send feeds: "33-34".
    public var lfeOutputs: String?
    /// Sets the speed of sound for Delay groups.
    public var airTemperatureC: Double
    /// The fastest a delay glides, as a pitch shift in percent.
    public var delayGlidePercent: Double
    /// A delay change bigger than this crossfades instead of gliding.
    public var delayJumpMS: Double
    public var delayCrossfadeMS: Double
    /// How long a change of groups, sends or renderers takes to crossfade (on reload).
    public var groupCrossfadeMS: Double
    /// Moves one source by itself, to hear the renderers move with only the test signal.
    public var testMotion: TestMotion?

    public init(device: String? = nil, sampleRate: Double = 48_000, bufferFrames: Int = 64,
                inputs: Int = 128, outputs: Int = 128, firstInputChannel: Int = 1, firstOutputChannel: Int = 1,
                routes: [Route] = [], refuseAggregateDevices: Bool = true,
                testSignal: TestSignal = .off, testSignalDB: Double = -20, testSignalHz: Double = 1000,
                speakers: [SpeakerConfig] = [], groups: [GroupConfig] = [], sources: [SourceConfig] = [],
                lfeOutputs: String? = nil, airTemperatureC: Double = 20, delayGlidePercent: Double = 0.5,
                delayJumpMS: Double = 5, delayCrossfadeMS: Double = 30, groupCrossfadeMS: Double = 50,
                testMotion: TestMotion? = nil) {
        self.device = device
        self.sampleRate = sampleRate
        self.bufferFrames = bufferFrames
        self.inputs = inputs
        self.outputs = outputs
        self.firstInputChannel = firstInputChannel
        self.firstOutputChannel = firstOutputChannel
        self.routes = routes
        self.refuseAggregateDevices = refuseAggregateDevices
        self.testSignal = testSignal
        self.testSignalDB = testSignalDB
        self.testSignalHz = testSignalHz
        self.speakers = speakers
        self.groups = groups
        self.sources = sources
        self.lfeOutputs = lfeOutputs
        self.airTemperatureC = airTemperatureC
        self.delayGlidePercent = delayGlidePercent
        self.delayJumpMS = delayJumpMS
        self.delayCrossfadeMS = delayCrossfadeMS
        self.groupCrossfadeMS = groupCrossfadeMS
        self.testMotion = testMotion
    }

    enum CodingKeys: String, CodingKey {
        case device, sampleRate, bufferFrames, inputs, outputs, firstInputChannel, firstOutputChannel, routes,
             refuseAggregateDevices, testSignal, testSignalDB, testSignalHz, speakers, groups, sources, lfeOutputs,
             airTemperatureC, delayGlidePercent, delayJumpMS, delayCrossfadeMS, groupCrossfadeMS, testMotion
    }

    /// Every key is optional in the file; missing ones take the defaults above.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EngineConfig()
        device = try c.decodeIfPresent(String.self, forKey: .device)
        sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? d.sampleRate
        bufferFrames = try c.decodeIfPresent(Int.self, forKey: .bufferFrames) ?? d.bufferFrames
        inputs = try c.decodeIfPresent(Int.self, forKey: .inputs) ?? d.inputs
        outputs = try c.decodeIfPresent(Int.self, forKey: .outputs) ?? d.outputs
        firstInputChannel = try c.decodeIfPresent(Int.self, forKey: .firstInputChannel) ?? d.firstInputChannel
        firstOutputChannel = try c.decodeIfPresent(Int.self, forKey: .firstOutputChannel) ?? d.firstOutputChannel
        routes = try c.decodeIfPresent([Route].self, forKey: .routes) ?? d.routes
        refuseAggregateDevices = try c.decodeIfPresent(Bool.self, forKey: .refuseAggregateDevices) ?? d.refuseAggregateDevices
        testSignal = try c.decodeIfPresent(TestSignal.self, forKey: .testSignal) ?? d.testSignal
        testSignalDB = try c.decodeIfPresent(Double.self, forKey: .testSignalDB) ?? d.testSignalDB
        testSignalHz = try c.decodeIfPresent(Double.self, forKey: .testSignalHz) ?? d.testSignalHz
        speakers = try c.decodeIfPresent([SpeakerConfig].self, forKey: .speakers) ?? d.speakers
        groups = try c.decodeIfPresent([GroupConfig].self, forKey: .groups) ?? d.groups
        sources = try c.decodeIfPresent([SourceConfig].self, forKey: .sources) ?? d.sources
        lfeOutputs = try c.decodeIfPresent(String.self, forKey: .lfeOutputs)
        airTemperatureC = try c.decodeIfPresent(Double.self, forKey: .airTemperatureC) ?? d.airTemperatureC
        delayGlidePercent = try c.decodeIfPresent(Double.self, forKey: .delayGlidePercent) ?? d.delayGlidePercent
        delayJumpMS = try c.decodeIfPresent(Double.self, forKey: .delayJumpMS) ?? d.delayJumpMS
        delayCrossfadeMS = try c.decodeIfPresent(Double.self, forKey: .delayCrossfadeMS) ?? d.delayCrossfadeMS
        groupCrossfadeMS = try c.decodeIfPresent(Double.self, forKey: .groupCrossfadeMS) ?? d.groupCrossfadeMS
        testMotion = try c.decodeIfPresent(TestMotion.self, forKey: .testMotion)
    }

    /// True when sources are rendered to speaker groups, rather than only the fixed routing played.
    public var isSpatial: Bool { !groups.isEmpty }

    /// The settings that need the audio device reopened when they change.
    public func sameDeviceSettings(as o: EngineConfig) -> Bool {
        device == o.device && sampleRate == o.sampleRate && bufferFrames == o.bufferFrames && inputs == o.inputs
            && outputs == o.outputs && firstInputChannel == o.firstInputChannel
            && firstOutputChannel == o.firstOutputChannel && refuseAggregateDevices == o.refuseAggregateDevices
    }

    /// How delays move, in samples at this sample rate.
    public var delayMotion: DelayMotion {
        DelayMotion(glideRate: delayGlidePercent / 100, jump: delayJumpMS / 1000 * sampleRate,
                    crossfade: delayCrossfadeMS / 1000 * sampleRate)
    }

    /// groupCrossfadeMS in samples.
    public var groupCrossfadeFrames: Int { Int((groupCrossfadeMS / 1000 * sampleRate).rounded()) }

    /// Where the engine looks for its settings: ~/Library/Application Support/Feral/engine.json.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Feral/engine.json")
    }

    public static func load(from url: URL) throws -> EngineConfig {
        let config = try JSONDecoder().decode(EngineConfig.self, from: Data(contentsOf: url))
        try config.validate()
        return config
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public func validate() throws {
        let max = Routing.maxChannels
        guard (0...max).contains(inputs), (0...max).contains(outputs) else {
            throw ConfigError("inputs and outputs must be from 0 to \(max)")
        }
        guard [44_100, 48_000].contains(sampleRate) else { throw ConfigError("sampleRate must be 48000 (or 44100)") }
        guard (16...4096).contains(bufferFrames) else { throw ConfigError("bufferFrames must be from 16 to 4096") }
        guard firstInputChannel >= 1, firstOutputChannel >= 1 else {
            throw ConfigError("firstInputChannel and firstOutputChannel count from 1")
        }
        guard testSignalDB <= 0 else { throw ConfigError("testSignalDB must be 0 or below") }
        guard testSignalHz >= 10, testSignalHz <= 20_000 else { throw ConfigError("testSignalHz must be from 10 to 20000") }
        if testSignal != .off && inputs < 1 { throw ConfigError("the test signal replaces input 1, so inputs must be 1 or more") }
        _ = try Routing(routes: routes, inputs: inputs, outputs: outputs)
        try validateSpatial()
    }

    private func validateSpatial() throws {
        guard (0...20).contains(delayGlidePercent) else { throw ConfigError("delayGlidePercent must be from 0 to 20") }
        guard delayJumpMS >= 0, delayCrossfadeMS >= 1, delayCrossfadeMS <= 1000 else {
            throw ConfigError("delayJumpMS must be 0 or more and delayCrossfadeMS from 1 to 1000")
        }
        guard (0...10_000).contains(groupCrossfadeMS) else { throw ConfigError("groupCrossfadeMS must be from 0 to 10000") }
        guard (-30...50).contains(airTemperatureC) else { throw ConfigError("airTemperatureC must be from -30 to 50") }

        var speakerOutputs = Set<Int>()
        for s in speakers {
            guard s.output >= 1, s.output <= outputs else { throw ConfigError("speaker \(s.label): output must be from 1 to \(outputs)") }
            guard speakerOutputs.insert(s.output).inserted else { throw ConfigError("two speakers play on output \(s.output)") }
            guard s.eq.count <= OutputParams.bands else { throw ConfigError("speaker \(s.label): at most \(OutputParams.bands) EQ bands") }
            for band in s.eq where !(band.hz > 0 && band.hz < sampleRate / 2) {
                throw ConfigError("speaker \(s.label): EQ frequency \(band.hz) must be between 0 and \(Int(sampleRate / 2)) Hz")
            }
            guard (0...1000).contains(s.delayMS) else { throw ConfigError("speaker \(s.label): delayMS must be from 0 to 1000") }
            if let l = s.limiterDB, l > 0 { throw ConfigError("speaker \(s.label): limiterDB must be 0 or below") }
        }

        var names = Set<String>()
        var delaySpeakers: [Int: String] = [:]
        for g in groups {
            guard names.insert(g.name).inserted else { throw ConfigError("two groups are called \(g.name)") }
            let outs = try Routing.channelList(g.speakers, limit: outputs, side: "output")
            for o in outs where !speakerOutputs.contains(o) {
                throw ConfigError("group \(g.name): output \(o) has no speaker (add it to speakers with its position)")
            }
            guard Set(outs).count == outs.count else { throw ConfigError("group \(g.name) lists a speaker twice") }
            for key in g.weightsDB.keys where Int(key).map({ !outs.contains($0) }) ?? true {
                throw ConfigError("group \(g.name): weightsDB names output \(key), which is not in the group")
            }
            if g.renderer == .delay {
                // A speaker in two Delay groups would get two delays for one source.
                for o in outs {
                    if let other = delaySpeakers[o] {
                        throw ConfigError("output \(o) is in two Delay groups (\(other) and \(g.name)); a speaker can be in one only")
                    }
                    delaySpeakers[o] = g.name
                }
                guard (0...200).contains(g.precedenceMS) else { throw ConfigError("group \(g.name): precedenceMS must be from 0 to 200") }
            }
            if g.renderer == .vbap, let d = g.dimensions, d != 2 && d != 3 { throw ConfigError("group \(g.name): dimensions must be 2 or 3") }
            guard g.rolloff >= 0, g.blur >= 0, g.rolloffDB >= 0 else {
                throw ConfigError("group \(g.name): rolloff, blur and rolloffDB must be 0 or more")
            }
        }

        var sourceInputs = Set<Int>()
        for s in sources {
            guard (1...max(inputs, 1)).contains(s.input), inputs > 0 else { throw ConfigError("source \(s.label): input must be from 1 to \(inputs)") }
            guard sourceInputs.insert(s.input).inserted else { throw ConfigError("two sources use input \(s.input)") }
            for name in (s.groups ?? [:]).keys where !names.contains(name) {
                throw ConfigError("source \(s.label) sends to group \(name), which does not exist")
            }
            if s.lfeDB != nil && lfeOutputs == nil { throw ConfigError("source \(s.label) has lfeDB but lfeOutputs is not set") }
        }
        if let lfe = lfeOutputs { _ = try Routing.channelList(lfe, limit: outputs, side: "output") }
        if !sources.isEmpty && groups.isEmpty { throw ConfigError("sources need at least one group to play through") }
        if let m = testMotion {
            guard sourceInputs.contains(m.source) else { throw ConfigError("testMotion: no source uses input \(m.source)") }
            guard m.seconds >= 1 else { throw ConfigError("testMotion: seconds must be 1 or more") }
        }
        // Building the renderer checks what is left (VBAP layouts it cannot pan between).
        if isSpatial { _ = try SpatialRenderer(config: self) }
    }
}

/// A generated signal the engine can play in place of input 1.
public enum TestSignal: String, Codable, Equatable {
    case off, pink, sine
}

public struct ConfigError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

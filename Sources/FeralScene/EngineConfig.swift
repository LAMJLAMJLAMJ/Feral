import Foundation

/// The engine's settings, read from engine.json. In milestone 1 this is all there is: one audio
/// device and a fixed routing. The show file replaces the routing in milestone 3.
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

    public init(device: String? = nil, sampleRate: Double = 48_000, bufferFrames: Int = 64,
                inputs: Int = 128, outputs: Int = 128, firstInputChannel: Int = 1, firstOutputChannel: Int = 1,
                routes: [Route] = [], refuseAggregateDevices: Bool = true) {
        self.device = device
        self.sampleRate = sampleRate
        self.bufferFrames = bufferFrames
        self.inputs = inputs
        self.outputs = outputs
        self.firstInputChannel = firstInputChannel
        self.firstOutputChannel = firstOutputChannel
        self.routes = routes
        self.refuseAggregateDevices = refuseAggregateDevices
    }

    enum CodingKeys: String, CodingKey {
        case device, sampleRate, bufferFrames, inputs, outputs, firstInputChannel, firstOutputChannel, routes,
             refuseAggregateDevices
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
    }

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
        _ = try Routing(routes: routes, inputs: inputs, outputs: outputs)
    }
}

public struct ConfigError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

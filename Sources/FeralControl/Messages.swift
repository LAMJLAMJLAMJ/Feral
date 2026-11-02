import FeralScene
import Foundation

// The control link between the engine and its clients (the Mac app, feral-cli): one JSON object per
// line over TCP, port 9100 by default. On connect the engine sends the whole show (`state`); after
// that it sends every command it applies (`applied`) to every client, so each client's copy of the
// show stays the engine's. Clients send requests. OSC and MIDI (ControlMapper) drive the same engine
// actions.

public let defaultControlPort = 9100

/// What a client asks the engine to do.
public enum Request: Codable, Equatable {
    /// Names the client in the engine's log and journal ("Feral app", "feral-cli").
    case hello(client: String)
    /// Applies a command to the show.
    case apply(command: Command)
    /// Recalls a snapshot (by number, id or name) over a fade (none: the snapshot's own time).
    case recall(snapshot: String, fadeSeconds: Double?)
    /// Runs a cue (by number or id), or with none the next one.
    case go(cue: String?)
    /// Stops every running fade where it is.
    case stopFades
    /// Saves the show to its package and empties the journal.
    case save
    /// Asks for the whole show again.
    case refresh
    /// Hands sources' positions back to cues from OSC or tracking.
    case release(sources: [UUID])
    /// Asks for the level meters (`meters` events, 20 a second) and for the OSC and MIDI the engine
    /// receives (`activity` events). Both are off until a client asks.
    case watch(meters: Bool, activity: Bool)
    /// Asks for the audio devices on the engine's Mac (answered with `devices`).
    case listDevices
    /// Switches the engine to an audio device (its UID, or part of its name) for both inputs and
    /// outputs: written to engine.json as `device`, and the device is reopened at once.
    case setDevice(device: String)
    /// Asks for the patch between the sound card's channels and the engine's (answered with `patch`).
    case getPatch
    /// Sets the patch: the device channel (from 1, 0 for none) for each engine input and output.
    /// Either may be left out to keep it. Written to engine.json as inputPatch and outputPatch; the
    /// audio reopens on the new patch at once (a short gap).
    case setPatch(inputs: [Int]?, outputs: [Int]?)
    /// Sets how many inputs and outputs Feral has (engine.json's inputs and outputs, up to 256);
    /// either may be left out to keep it. The audio reopens (a short gap).
    case setChannelCounts(inputs: Int?, outputs: Int?)
}

/// The patch between the sound card and the engine, for the app's Patch window.
public struct PatchInfo: Codable, Equatable {
    /// The device channel (from 1, 0 for none) each engine input reads, from input 1.
    public var inputs: [Int]
    /// The device channel (from 1, 0 for none) each engine output plays on.
    public var outputs: [Int]
    /// The open device and its channels; nil while none is open.
    public var device: String?
    public var deviceInputs: Int
    public var deviceOutputs: Int
    /// engine.json has a free patch (inputPatch / outputPatch) rather than channels in order.
    public var customInputs: Bool
    public var customOutputs: Bool

    public init(inputs: [Int], outputs: [Int], device: String?, deviceInputs: Int, deviceOutputs: Int,
                customInputs: Bool, customOutputs: Bool) {
        self.inputs = inputs; self.outputs = outputs; self.device = device; self.deviceInputs = deviceInputs
        self.deviceOutputs = deviceOutputs; self.customInputs = customInputs; self.customOutputs = customOutputs
    }
}

/// An audio device on the engine's Mac, as the app's sound card menu lists it.
public struct AudioDeviceSummary: Codable, Equatable, Identifiable {
    public var uid: String
    public var name: String
    /// "USB", "Thunderbolt", "PCI", "Virtual", "Aggregate", ...
    public var transport: String
    public var inputChannels: Int
    public var outputChannels: Int
    public var sampleRate: Double
    public var sampleRates: [Double]
    public var isAggregate: Bool

    public var id: String { uid }

    public init(uid: String, name: String, transport: String, inputChannels: Int, outputChannels: Int,
                sampleRate: Double, sampleRates: [Double], isAggregate: Bool) {
        self.uid = uid; self.name = name; self.transport = transport; self.inputChannels = inputChannels
        self.outputChannels = outputChannels; self.sampleRate = sampleRate; self.sampleRates = sampleRates
        self.isAggregate = isAggregate
    }

    /// engine.json's `device` names this device (its UID, or part of its name, as the engine matches it).
    public func matches(_ setting: String?) -> Bool {
        guard let setting, !setting.isEmpty else { return false }
        return uid == setting || name.localizedCaseInsensitiveContains(setting)
    }
}

/// The engine's state besides the show itself.
public struct EngineStatus: Codable, Equatable {
    public var version: String
    public var showPath: String
    /// Commands applied since the last save (they are in the journal, so a crash keeps them).
    public var unsaved: Int
    public var currentCue: UUID?
    public var nextCue: UUID?
    /// Sources a fade is moving now.
    public var fading: [UUID]
    /// "running on MADIface XT", "waiting: ...".
    public var audio: String
    /// Sources whose position something other than cues owns now, by source id.
    public var owners: [UUID: PositionOwner]
    /// "UDP port 9200", "off", or why it is not listening.
    public var osc: String
    /// "4 sources", "off".
    public var midi: String
    /// The UDP port the engine's OSC listens on, once it is listening.
    public var oscPort: Int?

    public init(version: String, showPath: String, unsaved: Int = 0, currentCue: UUID? = nil, nextCue: UUID? = nil,
                fading: [UUID] = [], audio: String = "", owners: [UUID: PositionOwner] = [:], osc: String = "", midi: String = "",
                oscPort: Int? = nil) {
        self.version = version; self.showPath = showPath; self.unsaved = unsaved; self.currentCue = currentCue
        self.nextCue = nextCue; self.fading = fading; self.audio = audio; self.owners = owners; self.osc = osc; self.midi = midi
        self.oscPort = oscPort
    }

    enum CodingKeys: String, CodingKey { case version, showPath, unsaved, currentCue, nextCue, fading, audio, owners, osc, midi, oscPort }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        showPath = try c.decode(String.self, forKey: .showPath)
        unsaved = try c.decodeIfPresent(Int.self, forKey: .unsaved) ?? 0
        currentCue = try c.decodeIfPresent(UUID.self, forKey: .currentCue)
        nextCue = try c.decodeIfPresent(UUID.self, forKey: .nextCue)
        fading = try c.decodeIfPresent([UUID].self, forKey: .fading) ?? []
        audio = try c.decodeIfPresent(String.self, forKey: .audio) ?? ""
        // Keyed by the id as text, so the JSON is an object.
        let byText = try c.decodeIfPresent([String: PositionOwner].self, forKey: .owners) ?? [:]
        owners = Dictionary(uniqueKeysWithValues: byText.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        osc = try c.decodeIfPresent(String.self, forKey: .osc) ?? ""
        midi = try c.decodeIfPresent(String.self, forKey: .midi) ?? ""
        oscPort = try c.decodeIfPresent(Int.self, forKey: .oscPort)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(showPath, forKey: .showPath)
        try c.encode(unsaved, forKey: .unsaved)
        try c.encodeIfPresent(currentCue, forKey: .currentCue)
        try c.encodeIfPresent(nextCue, forKey: .nextCue)
        try c.encode(fading, forKey: .fading)
        try c.encode(audio, forKey: .audio)
        try c.encode(Dictionary(uniqueKeysWithValues: owners.map { ($0.key.uuidString, $0.value) }), forKey: .owners)
        try c.encode(osc, forKey: .osc)
        try c.encode(midi, forKey: .midi)
        try c.encodeIfPresent(oscPort, forKey: .oscPort)
    }

    /// Who moves a source's position now.
    public func owner(of source: UUID) -> PositionOwner { owners[source] ?? .cues }
}

/// The whole show and status, sent when a client connects.
public struct FullState: Codable, Equatable {
    /// The number of commands the engine has applied since it started; each `applied` adds one.
    public var seq: Int
    public var show: Show
    public var system: SystemLayer
    public var status: EngineStatus

    public init(seq: Int, show: Show, system: SystemLayer, status: EngineStatus) {
        self.seq = seq; self.show = show; self.system = system; self.status = status
    }
}

/// The engine's level meters at one moment, for clients that asked (`watch`). Levels are dBFS to a
/// tenth of a dB, and `MeterFrame.silence` (-120) for nothing at all. Input n (from 1) is index n - 1,
/// the engine input sources name; output n is the engine output speakers name.
public struct MeterFrame: Codable, Equatable {
    public static let silence: Float = -120

    /// The highest sample since the last frame, per engine input.
    public var inputPeak: [Float]
    /// RMS over about 300 ms, per engine input.
    public var inputRMS: [Float]
    public var outputPeak: [Float]
    public var outputRMS: [Float]
    /// The device channel engine input 1 and output 1 are on (engine.json's firstInputChannel and
    /// firstOutputChannel), so a meter can say which device channel it is.
    public var firstInputChannel: Int
    public var firstOutputChannel: Int
    /// The render's highest share of a buffer's time in the last few seconds (1 is 100 %).
    public var load: Float
    /// Each input compressor's deepest gain reduction since the last frame, in dB (0 or more, to a
    /// tenth); none from engines before compressors.
    public var inputReduction: [Float]?

    public init(inputPeak: [Float], inputRMS: [Float], outputPeak: [Float], outputRMS: [Float],
                firstInputChannel: Int = 1, firstOutputChannel: Int = 1, load: Float = 0, inputReduction: [Float]? = nil) {
        self.inputPeak = inputPeak; self.inputRMS = inputRMS; self.outputPeak = outputPeak; self.outputRMS = outputRMS
        self.firstInputChannel = firstInputChannel; self.firstOutputChannel = firstOutputChannel; self.load = load
        self.inputReduction = inputReduction
    }

    /// A linear level as the frame carries it: dBFS to 0.1 dB, at least `silence`.
    public static func dB(_ linear: Float) -> Float {
        guard linear > 0 else { return silence }
        return max(silence, Float((200 * log10(Double(linear))).rounded() / 10))
    }
}

/// An OSC or MIDI message the engine received and what it did with it, for clients that asked
/// (`watch`), such as the app's control monitor.
public struct ControlActivity: Codable, Equatable {
    public enum Kind: String, Codable { case osc, midi }

    /// Seconds since 1970.
    public var time: Double
    public var kind: Kind
    /// Who sent it: "127.0.0.1:53000", or the MIDI source's name.
    public var from: String
    /// The message as text: "/feral/go 3", "program change 5 on channel 1".
    public var message: String
    /// What the engine did: "GO cue 3", or why it did nothing.
    public var result: String
    /// False when nothing listens for it or it could not be done.
    public var handled: Bool

    public init(time: Double, kind: Kind, from: String, message: String, result: String, handled: Bool) {
        self.time = time; self.kind = kind; self.from = from; self.message = message; self.result = result
        self.handled = handled
    }
}

/// What the engine sends its clients.
public enum Event: Codable, Equatable {
    case state(state: FullState)
    case applied(seq: Int, origin: String, command: Command)
    case status(status: EngineStatus)
    /// A request was refused, or something went wrong; the show did not change.
    case error(message: String)
    /// Level meters, 20 a second, to clients that asked.
    case meters(frame: MeterFrame)
    /// OSC and MIDI received in the last moment, to clients that asked. `dropped` counts messages
    /// left out because too many came at once (a tracker streaming positions).
    case activity(lines: [ControlActivity], dropped: Int)
    /// The audio devices on the engine's Mac, and engine.json's `device` setting.
    case devices(list: [AudioDeviceSummary], selected: String?)
    /// The patch between the sound card and the engine: to the client that asked, and to everyone
    /// when it changes.
    case patch(patch: PatchInfo)
}

/// Newline-framed JSON.
public enum Wire {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try ShowFile.encoder(pretty: false).encode(value)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try ShowFile.decoder().decode(type, from: line)
    }

    /// Collects received bytes and hands back complete lines.
    public struct LineBuffer {
        private var pending = Data()
        /// A client that sends a line longer than this is cut off.
        public static let maxLine = 16 << 20

        public init() {}

        public mutating func append(_ data: Data) throws -> [Data] {
            pending.append(data)
            var lines: [Data] = []
            while let i = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<i]
                if !line.isEmpty { lines.append(Data(line)) }
                pending = Data(pending[pending.index(after: i)...])
            }
            if pending.count > LineBuffer.maxLine { throw ConfigError("a message was longer than 16 MB") }
            return lines
        }
    }
}

/// A show kept the engine's by applying its events, as the app and feral-cli do.
public struct MirroredShow {
    public var state: ShowState?
    public var status: EngineStatus?
    public var seq = 0

    public init() {}

    /// Applies an event. Returns false if a command could not be applied (the copy has drifted), in
    /// which case send `refresh`.
    @discardableResult
    public mutating func handle(_ event: Event) -> Bool {
        switch event {
        case .state(let full):
            state = ShowState(show: full.show, system: full.system)
            status = full.status
            seq = full.seq
        case .applied(let n, _, let command):
            guard var s = state else { return false }
            do { try s.apply(command) } catch { return false }
            state = s
            if n != seq + 1 { seq = n; return false }
            seq = n
        case .status(let s):
            status = s
        case .error, .meters, .activity, .devices, .patch:
            break
        }
        return true
    }
}

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

    public init(version: String, showPath: String, unsaved: Int = 0, currentCue: UUID? = nil, nextCue: UUID? = nil,
                fading: [UUID] = [], audio: String = "", owners: [UUID: PositionOwner] = [:], osc: String = "", midi: String = "") {
        self.version = version; self.showPath = showPath; self.unsaved = unsaved; self.currentCue = currentCue
        self.nextCue = nextCue; self.fading = fading; self.audio = audio; self.owners = owners; self.osc = osc; self.midi = midi
    }

    enum CodingKeys: String, CodingKey { case version, showPath, unsaved, currentCue, nextCue, fading, audio, owners, osc, midi }

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

/// What the engine sends its clients.
public enum Event: Codable, Equatable {
    case state(state: FullState)
    case applied(seq: Int, origin: String, command: Command)
    case status(status: EngineStatus)
    /// A request was refused, or something went wrong; the show did not change.
    case error(message: String)
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
        case .error:
            break
        }
        return true
    }
}

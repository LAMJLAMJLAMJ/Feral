import Foundation

/// One line of a show's journal: a command the engine applied, when, and who sent it.
public struct JournalEntry: Codable, Equatable {
    public var seq: Int
    public var time: Date
    /// "app", "feral-cli", "fade", "cue 12"...
    public var origin: String
    public var command: Command

    public init(seq: Int, time: Date = Date(), origin: String, command: Command) {
        self.seq = seq; self.time = time; self.origin = origin; self.command = command
    }

    /// Joins neighbouring source updates into one, the later values on top, so a drag or a fade
    /// written every 100 ms takes one line rather than one per step.
    public static func coalesce(_ entries: [JournalEntry]) -> [JournalEntry] {
        var result: [JournalEntry] = []
        for e in entries {
            if case .updateSources(let newer) = e.command, let last = result.last, case .updateSources(let older) = last.command {
                var merged = older
                for u in newer {
                    if let i = merged.firstIndex(where: { $0.id == u.id }) {
                        merged[i].values = merged[i].values.merged(with: u.values)
                    } else {
                        merged.append(u)
                    }
                }
                result[result.count - 1] = JournalEntry(seq: e.seq, time: e.time, origin: e.origin,
                                                        command: .updateSources(updates: merged))
            } else {
                result.append(e)
            }
        }
        return result
    }
}

/// A .feralshow package: a folder that holds
///
///     show.json      the sources, groups, snapshots and cues
///     system.json    the speakers and their system layer
///     journal/journal.jsonl    every command since the last save, one JSON object per line
///
/// Saving writes show.json and system.json and empties the journal. Opening reads them and replays
/// the journal, so after a crash the show comes back exactly where it was, unsaved changes included.
public enum ShowFile {
    public static let fileExtension = "feralshow"

    public struct Opened {
        public var url: URL
        public var state: ShowState
        /// Journal entries replayed on top of the saved files (changes since the last save).
        public var replayed: Int
        /// Lines that could not be read (a line cut short by a crash) or applied, with why.
        public var problems: [String]
        /// False when the package did not exist and the state was made from engine.json instead.
        public var exists: Bool
    }

    static func showURL(_ package: URL) -> URL { package.appendingPathComponent("show.json") }
    static func systemURL(_ package: URL) -> URL { package.appendingPathComponent("system.json") }
    public static func journalURL(_ package: URL) -> URL { package.appendingPathComponent("journal/journal.jsonl") }

    public static func encoder(pretty: Bool) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Reads a package and replays its journal.
    public static func load(_ url: URL) throws -> Opened {
        let show: Show
        let system: SystemLayer
        do { show = try decoder().decode(Show.self, from: Data(contentsOf: showURL(url))) } catch {
            throw ConfigError("\(showURL(url).path): \(describe(error))")
        }
        let systemFile = systemURL(url)
        if FileManager.default.fileExists(atPath: systemFile.path) {
            do { system = try decoder().decode(SystemLayer.self, from: Data(contentsOf: systemFile)) } catch {
                throw ConfigError("\(systemFile.path): \(describe(error))")
            }
        } else {
            system = SystemLayer()
        }
        var state = ShowState(show: show, system: system)
        try state.validate()
        var replayed = 0
        var problems: [String] = []
        for (n, line) in readJournal(url).enumerated() {
            do {
                let entry = try decoder().decode(JournalEntry.self, from: line)
                try state.apply(entry.command)
                replayed += 1
            } catch {
                problems.append("journal line \(n + 1): \(describe(error))")
            }
        }
        return Opened(url: url, state: state, replayed: replayed, problems: problems, exists: true)
    }

    /// The journal's lines, empty ones left out.
    static func readJournal(_ url: URL) -> [Data] {
        guard let data = try? Data(contentsOf: journalURL(url)) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).filter { !$0.isEmpty }.map { Data($0) }
    }

    /// Writes show.json and system.json, then empties the journal.
    public static func save(_ state: ShowState, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("journal"), withIntermediateDirectories: true)
        let e = encoder(pretty: true)
        try e.encode(state.show).write(to: showURL(url), options: .atomic)
        try e.encode(state.system).write(to: systemURL(url), options: .atomic)
        try Data().write(to: journalURL(url), options: .atomic)
    }

    /// Where engine.json's show is: its `show` key (absolute, from ~, or relative to engine.json's
    /// folder), or Shows/Default.feralshow next to engine.json.
    public static func url(for config: EngineConfig, configURL: URL) -> URL {
        let folder = configURL.deletingLastPathComponent()
        guard let path = config.show, !path.isEmpty else {
            return folder.appendingPathComponent("Shows/Default.\(fileExtension)")
        }
        let expanded = NSString(string: path).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : folder.appendingPathComponent(expanded)
    }

    /// Opens engine.json's show. If the package does not exist yet, makes the show from engine.json's
    /// own speakers, groups and sources (empty if it has none) and returns it with `exists` false; the
    /// engine then saves it there, so a milestone 2 layout carries over by itself.
    public static func open(for config: EngineConfig, configURL: URL) throws -> Opened {
        let url = url(for: config, configURL: configURL)
        if FileManager.default.fileExists(atPath: showURL(url).path) { return try load(url) }
        let name = url.deletingPathExtension().lastPathComponent
        return Opened(url: url, state: try ShowState.importing(config, name: name), replayed: 0, problems: [], exists: false)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let ctx):
            return "missing \(key.stringValue)" + path(ctx.codingPath)
        case DecodingError.typeMismatch(_, let ctx), DecodingError.valueNotFound(_, let ctx):
            return ctx.debugDescription + path(ctx.codingPath)
        case DecodingError.dataCorrupted(let ctx):
            return ctx.debugDescription + path(ctx.codingPath)
        default:
            return "\(error)"
        }
    }

    private static func path(_ keys: [CodingKey]) -> String {
        keys.isEmpty ? "" : " at " + keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    }
}

/// Appends entries to a show's journal and flushes them to disk. Not thread-safe: use it from one queue.
public final class Journal {
    public let url: URL
    private var handle: FileHandle?

    public init(package: URL) throws {
        url = ShowFile.journalURL(package)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    deinit { try? handle?.close() }

    public func append(_ entries: [JournalEntry]) throws {
        guard !entries.isEmpty else { return }
        let encoder = ShowFile.encoder(pretty: false)
        var data = Data()
        for e in entries {
            data.append(try encoder.encode(e))
            data.append(UInt8(ascii: "\n"))
        }
        let h = try openHandle()
        _ = try h.seekToEnd()
        try h.write(contentsOf: data)
        try h.synchronize()
    }

    /// Call after ShowFile.save emptied the file, so the next append starts the new file.
    public func reopen() {
        try? handle?.close()
        handle = nil
    }

    private func openHandle() throws -> FileHandle {
        if let handle { return handle }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try FileHandle(forWritingTo: url)
        handle = h
        return h
    }
}

import Foundation

/// A change to the show. Every client (the app, feral-cli, OSC, MIDI and cues) changes the show only
/// through commands; the engine applies them, writes each to the journal and sends it to every
/// client, which applies it to its own copy. Commands carry every id they need and apply the same way
/// each time, so replaying the journal brings back exactly the state that was live.
public enum Command: Codable, Equatable {
    /// Moves sources or changes their live values (position, gain, mute, width, sends, LFE send).
    case updateSources(updates: [SourceUpdate])
    /// Adds a source, or replaces the one with the same id.
    case setSource(source: Source)
    case removeSource(id: UUID)
    /// Adds a speaker, or replaces the one with the same id (its position or its system layer).
    case setSpeaker(speaker: Speaker)
    case removeSpeaker(id: UUID)
    /// Adds a group, or replaces the one with the same id.
    case setGroup(group: SpeakerGroup)
    case removeGroup(id: UUID)
    case setLFESpeakers(speakers: [UUID])
    /// Sets the LFE group's algorithm and level.
    case setLFE(mode: LFEMode, gainDB: Double)
    /// Moves or turns the listening point that azimuth, elevation and distance are measured from.
    case setListener(listener: Listener)
    /// Adds a source group, or replaces the one with the same id (members, gain, mute, name).
    case setSourceGroup(group: SourceGroup)
    case removeSourceGroup(id: UUID)
    /// Stores the sources' current values as a snapshot (adding it, or updating the one with that id).
    case captureSnapshot(capture: SnapshotCapture)
    /// Adds a snapshot as given, or replaces the one with the same id (a rename or a new fade time).
    case setSnapshot(snapshot: Snapshot)
    case removeSnapshot(id: UUID)
    /// Adds a cue, or replaces the one with the same id.
    case setCue(cue: Cue)
    case removeCue(id: UUID)
    case renameShow(name: String)
    /// Replaces the show's control settings: the ADM-OSC box, the trigger map, the MSC device id.
    case setControl(control: ControlSettings)
    /// Adds a reverb room, or replaces the one with the same id.
    case setRoom(room: Room)
    /// Removes a room; the sources that played into it play into none.
    case removeRoom(id: UUID)

    /// The sources whose values the command sets directly, so a fade running on them stops.
    public var touchedSources: [UUID] {
        switch self {
        case .updateSources(let updates): return updates.map(\.id)
        case .setSource(let source): return [source.id]
        case .removeSource(let id): return [id]
        default: return []
        }
    }
}

/// The show and its system layer, as the engine holds it and every client mirrors it.
public struct ShowState: Equatable {
    public var show: Show
    public var system: SystemLayer

    public init(show: Show, system: SystemLayer = SystemLayer()) {
        self.show = show; self.system = system
    }

    /// What applying a command needs the renderer to do.
    public enum Change: Equatable {
        /// Nothing is heard differently (a snapshot, a cue, a name).
        case none
        /// Only these sources' taps change.
        case sources([UUID])
        /// The layout changed: the renderer is rebuilt. `crossfade` asks for the slow group crossfade
        /// (groups, sends or renderers changed) rather than the one-buffer ramp (a speaker moved).
        case layout(crossfade: Bool)
    }

    // MARK: Lookups

    public func sourceIndex(_ id: UUID) -> Int? { show.sources.firstIndex { $0.id == id } }
    public func source(_ id: UUID) -> Source? { show.sources.first { $0.id == id } }
    public func speaker(_ id: UUID) -> Speaker? { system.speakers.first { $0.id == id } }
    public func group(_ id: UUID) -> SpeakerGroup? { show.groups.first { $0.id == id } }
    public func sourceGroup(_ id: UUID) -> SourceGroup? { show.sourceGroups.first { $0.id == id } }
    /// The source groups a source is in.
    public func sourceGroups(of source: UUID) -> [SourceGroup] { show.sourceGroups.filter { $0.sources.contains(source) } }
    public var nextSourceGroupNumber: Int { (show.sourceGroups.map(\.number).max() ?? 0) + 1 }
    public var nextGroupNumber: Int { (show.groups.map(\.number).max() ?? 0) + 1 }
    public func snapshot(_ id: UUID) -> Snapshot? { show.snapshots.first { $0.id == id } }
    public func cue(_ id: UUID) -> Cue? { show.cues.first { $0.id == id } }
    public func room(_ id: UUID) -> Room? { show.rooms.first { $0.id == id } }
    public var nextRoomNumber: Int { (show.rooms.map(\.number).max() ?? 0) + 1 }

    /// A source by its number or id, as typed.
    public func source(matching text: String) -> Source? {
        if let n = Int(text) { return show.sources.first { $0.number == n } }
        return UUID(uuidString: text).flatMap { source($0) }
    }

    /// A snapshot by its number, its id or its name, as typed.
    public func snapshot(matching text: String) -> Snapshot? {
        if let n = Int(text), let s = show.snapshots.first(where: { $0.number == n }) { return s }
        if let id = UUID(uuidString: text), let s = snapshot(id) { return s }
        return show.snapshots.first { $0.name.lowercased() == text.lowercased() }
    }

    /// A cue by its number ("12.5") or id.
    public func cue(matching text: String) -> Cue? {
        if let id = UUID(uuidString: text) { return cue(id) }
        if let n = Double(text) { return show.cues.first { $0.order == n } }
        return show.cues.first { $0.number == text }
    }

    /// The cue list in the order GO runs it.
    public var orderedCues: [Cue] {
        show.cues.enumerated().sorted { a, b in
            a.element.order != b.element.order ? a.element.order < b.element.order : a.offset < b.offset
        }.map(\.element)
    }

    /// The cue GO runs after `current` (none: the first).
    public func cue(after current: UUID?) -> Cue? {
        let list = orderedCues
        guard let current, let i = list.firstIndex(where: { $0.id == current }) else { return list.first }
        return i + 1 < list.count ? list[i + 1] : nil
    }

    public var nextSourceNumber: Int { (show.sources.map(\.number).max() ?? 0) + 1 }
    public var nextSnapshotNumber: Int { (show.snapshots.map(\.number).max() ?? 0) + 1 }
    public var nextCueNumber: String { String(Int(show.cues.map(\.order).filter(\.isFinite).max() ?? 0) + 1) }

    // MARK: Applying commands

    /// Applies a command. Throws, changing nothing, when it names something that does not exist or
    /// would leave the show inconsistent. The engine also checks that the result can be rendered
    /// (EngineConfig.validate) before it keeps a layout change.
    @discardableResult
    public mutating func apply(_ command: Command) throws -> Change {
        var next = self
        let change = try next.applyUnchecked(command)
        if case .layout = change { try next.validate() }
        self = next
        return change
    }

    private mutating func applyUnchecked(_ command: Command) throws -> Change {
        switch command {
        case .updateSources(let updates):
            var ids: [UUID] = []
            for u in updates {
                guard let i = sourceIndex(u.id) else { throw ConfigError("no source has id \(u.id)") }
                show.sources[i] = try applying(u.values, to: show.sources[i])
                if !ids.contains(u.id) { ids.append(u.id) }
                // A stereo pair's level, mute, EQ and compressor are always the same on both sides.
                let shared = SourceValues(gainDB: u.values.gainDB, mute: u.values.mute, width: u.values.width, eq: u.values.eq,
                                          compressor: u.values.compressor, trimDB: u.values.trimDB,
                                          invert: u.values.invert, delayMS: u.values.delayMS, distance: u.values.distance,
                                          reverb: u.values.reverb)
                if !shared.isEmpty, let partner = stereoPartner(of: u.id), let j = sourceIndex(partner) {
                    show.sources[j] = try applying(shared, to: show.sources[j])
                    if !ids.contains(partner) { ids.append(partner) }
                }
            }
            return .sources(ids)

        case .setSource(let source):
            try checkValues(source)
            if let i = sourceIndex(source.id) {
                let sameInput = show.sources[i].input == source.input
                show.sources[i] = source
                return sameInput ? .sources([source.id]) : .layout(crossfade: true)
            }
            show.sources.append(source)
            return .layout(crossfade: true)

        case .removeSource(let id):
            guard let i = sourceIndex(id) else { throw ConfigError("no source has id \(id)") }
            show.sources.remove(at: i)
            for g in show.sourceGroups.indices { show.sourceGroups[g].sources.removeAll { $0 == id } }
            return .layout(crossfade: true)

        case .setSourceGroup(let group):
            guard group.gainDB.isFinite, group.gainDB <= 24 else { throw ConfigError("group \(group.label): gainDB must be 24 or below") }
            for m in group.sources where sourceIndex(m) == nil { throw ConfigError("group \(group.label) lists source \(m), which does not exist") }
            var touched = Set(group.sources)
            if let i = show.sourceGroups.firstIndex(where: { $0.id == group.id }) {
                touched.formUnion(show.sourceGroups[i].sources)
                show.sourceGroups[i] = group
            } else {
                show.sourceGroups.append(group)
            }
            return .sources(show.sources.map(\.id).filter { touched.contains($0) })

        case .setListener(let l):
            let p = l.position
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite, abs(p.x) < 10_000, abs(p.y) < 10_000, abs(p.z) < 10_000,
                  l.facing.isFinite else { throw ConfigError("the listener must be finite and within 10 km") }
            system.listener = Listener(position: p, facing: Self.wrap(l.facing))
            // Panning by direction, spread and distance modelling all work from the listener.
            return .layout(crossfade: true)

        case .removeSourceGroup(let id):
            guard let i = show.sourceGroups.firstIndex(where: { $0.id == id }) else { throw ConfigError("no source group has id \(id)") }
            let members = Set(show.sourceGroups[i].sources)
            show.sourceGroups.remove(at: i)
            return .sources(show.sources.map(\.id).filter { members.contains($0) })

        case .setSpeaker(let speaker):
            if let i = system.speakers.firstIndex(where: { $0.id == speaker.id }) {
                system.speakers[i] = speaker
            } else {
                system.speakers.append(speaker)
            }
            return .layout(crossfade: false)

        case .removeSpeaker(let id):
            guard let i = system.speakers.firstIndex(where: { $0.id == id }) else { throw ConfigError("no speaker has id \(id)") }
            system.speakers.remove(at: i)
            for g in show.groups.indices {
                show.groups[g].speakers.removeAll { $0 == id }
                show.groups[g].weightsDB[id.uuidString] = nil
            }
            system.lfeSpeakers.removeAll { $0 == id }
            for r in show.rooms.indices { show.rooms[r].speakers.removeAll { $0 == id } }
            return .layout(crossfade: true)

        case .setGroup(let group):
            guard group.name != Self.lfeGroupName else { throw ConfigError("\(Self.lfeGroupName) is the LFE group's name; pick another") }
            if let i = show.groups.firstIndex(where: { $0.id == group.id }) {
                show.groups[i] = group
            } else {
                show.groups.append(group)
            }
            return .layout(crossfade: true)

        case .removeGroup(let id):
            guard let i = show.groups.firstIndex(where: { $0.id == id }) else { throw ConfigError("no group has id \(id)") }
            show.groups.remove(at: i)
            for s in show.sources.indices { show.sources[s].sends.removeAll { $0.group == id } }
            for n in show.snapshots.indices {
                for k in show.snapshots[n].sources.indices {
                    show.snapshots[n].sources[k].values.sends?.removeAll { $0.group == id }
                }
            }
            return .layout(crossfade: true)

        case .setLFESpeakers(let speakers):
            system.lfeSpeakers = speakers
            return .layout(crossfade: true)

        case .setLFE(let mode, let gainDB):
            guard gainDB.isFinite, (-60...20).contains(gainDB) else { throw ConfigError("the LFE group's level must be from -60 to 20 dB") }
            system.lfeMode = mode
            system.lfeGainDB = gainDB
            return .layout(crossfade: true)

        case .captureSnapshot(let capture):
            let snap = self.capture(capture)
            if let i = show.snapshots.firstIndex(where: { $0.id == capture.id }) {
                show.snapshots[i] = snap
            } else {
                show.snapshots.append(snap)
            }
            return .none

        case .setSnapshot(let snapshot):
            if let i = show.snapshots.firstIndex(where: { $0.id == snapshot.id }) {
                show.snapshots[i] = snapshot
            } else {
                show.snapshots.append(snapshot)
            }
            return .none

        case .removeSnapshot(let id):
            guard let i = show.snapshots.firstIndex(where: { $0.id == id }) else { throw ConfigError("no snapshot has id \(id)") }
            show.snapshots.remove(at: i)
            for c in show.cues.indices where show.cues[c].snapshot == id { show.cues[c].snapshot = nil }
            return .none

        case .setCue(let cue):
            guard cue.order.isFinite else { throw ConfigError("cue number \(cue.number) is not a number such as 12 or 12.5") }
            if let s = cue.snapshot, snapshot(s) == nil { throw ConfigError("cue \(cue.number): no snapshot has id \(s)") }
            if let f = cue.fadeSeconds, !(0...3600).contains(f) { throw ConfigError("cue \(cue.number): fadeSeconds must be from 0 to 3600") }
            if let i = show.cues.firstIndex(where: { $0.id == cue.id }) {
                show.cues[i] = cue
            } else {
                show.cues.append(cue)
            }
            return .none

        case .removeCue(let id):
            guard let i = show.cues.firstIndex(where: { $0.id == id }) else { throw ConfigError("no cue has id \(id)") }
            show.cues.remove(at: i)
            return .none

        case .renameShow(let name):
            show.name = name
            return .none

        case .setControl(let control):
            try control.check()
            show.control = control
            return .none

        case .setRoom(let room):
            try room.check()
            for s in room.speakers where speaker(s) == nil { throw ConfigError("room \(room.label) lists speaker \(s), which does not exist") }
            if let i = show.rooms.firstIndex(where: { $0.id == room.id }) {
                show.rooms[i] = room
                // A room's settings change smoothly in the core: no crossfade.
                return .layout(crossfade: false)
            }
            guard show.rooms.count < Room.maxRooms else { throw ConfigError("a show has at most \(Room.maxRooms) rooms") }
            show.rooms.append(room)
            return .layout(crossfade: true)

        case .removeRoom(let id):
            guard let i = show.rooms.firstIndex(where: { $0.id == id }) else { throw ConfigError("no room has id \(id)") }
            show.rooms.remove(at: i)
            for k in show.sources.indices where show.sources[k].reverb?.room == id { show.sources[k].reverb = nil }
            for n in show.snapshots.indices {
                for k in show.snapshots[n].sources.indices where show.snapshots[n].sources[k].values.reverb?.room == id {
                    show.snapshots[n].sources[k].values.reverb = .off
                }
            }
            return .layout(crossfade: true)
        }
    }

    /// A source with some values replaced.
    public func applying(_ v: SourceValues, to source: Source) throws -> Source {
        var s = source
        if let p = v.position { s.position = p }
        if let g = v.gainDB { s.gainDB = g }
        if let m = v.mute { s.mute = m }
        if let w = v.width { s.width = w }
        if let sends = v.sends { s.sends = sends }
        if v.lfeOff == true { s.lfeDB = nil } else if let l = v.lfeDB { s.lfeDB = l }
        if let e = v.eq { s.eq = e }
        if let c = v.compressor { s.compressor = c }
        if let t = v.trimDB { s.trimDB = t }
        if let i = v.invert { s.invert = i }
        if let d = v.delayMS { s.delayMS = d }
        if let d = v.distance { s.distance = d }
        if let r = v.reverb { s.reverb = r.room == nil ? nil : r }
        try checkValues(s)
        return s
    }

    private func checkValues(_ s: Source) throws {
        let p = s.position
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite, abs(p.x) < 10_000, abs(p.y) < 10_000, abs(p.z) < 10_000 else {
            throw ConfigError("source \(s.label): position must be finite and within 10 km")
        }
        guard s.gainDB.isFinite, s.gainDB <= 24 else { throw ConfigError("source \(s.label): gainDB must be 24 or below") }
        guard s.width.isFinite, (0...360).contains(s.width) else { throw ConfigError("source \(s.label): width must be from 0 to 360") }
        for send in s.sends {
            guard group(send.group) != nil else { throw ConfigError("source \(s.label) sends to group \(send.group), which does not exist") }
            guard send.gainDB.isFinite, send.gainDB <= 24 else { throw ConfigError("source \(s.label): send levels must be 24 dB or below") }
        }
        if let l = s.lfeDB { guard l.isFinite, l <= 24 else { throw ConfigError("source \(s.label): lfeDB must be 24 or below") } }
        guard s.trimDB.isFinite, abs(s.trimDB) <= 24 else { throw ConfigError("source \(s.label): trim must be within ±24 dB") }
        guard s.delayMS.isFinite, (0...1000).contains(s.delayMS) else { throw ConfigError("source \(s.label): delay must be from 0 to 1000 ms") }
        try s.eq?.check("source \(s.label)")
        try s.compressor?.check("source \(s.label)")
        try s.distance?.check("source \(s.label)")
        if let r = s.reverb {
            try r.check("source \(s.label)")
            if let id = r.room, room(id) == nil { throw ConfigError("source \(s.label) plays into room \(id), which does not exist") }
        }
    }

    /// Checks ids and references. Rendering checks (inputs and outputs in range, VBAP layouts) are
    /// EngineConfig.validate's, through engineConfig(base:).
    public func validate() throws {
        func unique<T: Hashable>(_ values: [T], _ what: String) throws {
            var seen = Set<T>()
            for v in values where !seen.insert(v).inserted { throw ConfigError("two \(what) \(v)") }
        }
        try unique(show.sources.map(\.id), "sources have the id")
        try unique(show.groups.map(\.id), "groups have the id")
        try unique(show.sourceGroups.map(\.id), "source groups have the id")
        try unique(system.speakers.map(\.id), "speakers have the id")
        try unique(show.snapshots.map(\.id), "snapshots have the id")
        try unique(show.cues.map(\.id), "cues have the id")
        try unique(show.rooms.map(\.id), "rooms have the id")
        guard show.rooms.count <= Room.maxRooms else { throw ConfigError("a show has at most \(Room.maxRooms) rooms") }
        for r in show.rooms {
            try r.check()
            for s in r.speakers where speaker(s) == nil { throw ConfigError("room \(r.label) lists speaker \(s), which does not exist") }
        }
        try unique(show.groups.map(\.name), "groups are called")
        if show.groups.contains(where: { $0.name == Self.lfeGroupName }) { throw ConfigError("a group is called \(Self.lfeGroupName), the LFE group's name") }
        try unique(system.speakers.map(\.output), "speakers play on output")
        try unique(show.sources.map(\.input), "sources use input")
        for g in show.groups {
            for s in g.speakers where speaker(s) == nil { throw ConfigError("group \(g.name) lists speaker \(s), which does not exist") }
        }
        for s in show.sources { try checkValues(s) }
        for s in system.lfeSpeakers where speaker(s) == nil { throw ConfigError("the LFE speakers list \(s), which does not exist") }
        try show.control.check()
    }

    // MARK: Snapshots

    /// A source's current values, every field.
    public func values(of s: Source) -> SourceValues {
        SourceValues(position: s.position, gainDB: s.gainDB, mute: s.mute, width: s.width, sends: s.sends,
                     lfeDB: s.lfeDB, lfeOff: s.lfeDB == nil ? true : nil, eq: s.eq ?? .flat, compressor: s.compressor ?? .off,
                     trimDB: s.trimDB, invert: s.invert, delayMS: s.delayMS, distance: s.distance ?? .off,
                     reverb: s.reverb ?? .off)
    }

    /// The fields a snapshot stores (for any of its sources).
    public func fields(of snapshot: Snapshot) -> Set<SnapshotField> {
        snapshot.sources.reduce(into: Set<SnapshotField>()) { $0.formUnion(SnapshotField.present(in: $1.values)) }
    }

    /// A snapshot that stores one more field, taken from its sources as they are now, or one fewer.
    public func snapshot(_ snapshot: Snapshot, storing field: SnapshotField, _ on: Bool) -> Snapshot {
        var s = snapshot
        s.sources = s.sources.map { stored in
            var v = stored.values
            if let source = source(stored.id) { field.copy(from: values(of: source), into: &v, on) } else if !on { field.copy(from: v, into: &v, false) }
            return SourceUpdate(id: stored.id, values: v)
        }
        return s
    }

    /// The snapshot a capture makes from the sources as they are now.
    public func capture(_ c: SnapshotCapture) -> Snapshot {
        let scope = c.sources.map(Set.init)
        let fields = Set(c.fields ?? SnapshotField.allCases)
        let stored = show.sources.filter { scope?.contains($0.id) ?? true }.map { s -> SourceUpdate in
            let all = values(of: s)
            var v = SourceValues()
            for f in fields { f.copy(from: all, into: &v) }
            return SourceUpdate(id: s.id, values: v)
        }
        return Snapshot(id: c.id, number: c.number, name: c.name, fadeSeconds: c.fadeSeconds, curve: c.curve, sources: stored)
    }

    // MARK: To and from the renderer's settings

    /// Moves sources onto their nearest speakers: of the speakers in the groups each one sends to
    /// (any speaker when it sends nowhere), not LFE speakers. Several can land on one speaker.
    public func snappedToNearestSpeakers(_ ids: [UUID]) -> [SourceUpdate] {
        ids.compactMap { id -> SourceUpdate? in
            guard let s = source(id) else { return nil }
            let groups = Set(s.sends.map(\.group))
            let inGroups = Set(show.groups.filter { groups.contains($0.id) }.flatMap(\.speakers))
            var candidates = system.speakers.filter { !system.lfeSpeakers.contains($0.id) }
            if !inGroups.isEmpty, candidates.contains(where: { inGroups.contains($0.id) }) {
                candidates = candidates.filter { inGroups.contains($0.id) }
            }
            guard let nearest = candidates.min(by: { $0.position.distance(to: s.position) < $1.position.distance(to: s.position) }) else {
                return nil
            }
            return SourceUpdate(id: id, values: SourceValues(position: nearest.position))
        }
    }

    /// Whether a speaker group has enough speakers to render. One that has not (none, or one for
    /// VBAP) plays nothing and is left out of the renderer's settings, so a group can be built up a
    /// speaker at a time.
    public func isPlayable(_ g: SpeakerGroup) -> Bool {
        g.speakers.filter { speaker($0) != nil }.count >= (g.renderer == .vbap ? 2 : 1)
    }

    /// A source as the renderer takes it, with its sends by group name.
    public func sourceConfig(_ s: Source) -> SourceConfig {
        var sends: [String: Double] = [:]
        for send in s.sends { if let g = group(send.group), isPlayable(g) { sends[g.name] = send.gainDB } }
        // The LFE send, with the LFE group's level: straight to every sub (equal), or through a
        // Delay or DBAP group of the subs.
        let lfeSend = system.lfeSpeakers.contains { speaker($0) != nil } ? s.lfeDB.map { $0 + system.lfeGainDB } : nil
        if system.lfeMode != .equal, let l = lfeSend { sends[Self.lfeGroupName] = l }
        // Source groups act like VCAs: their gains add, and any muted group mutes the source.
        let groups = sourceGroups(of: s.id)
        let d = s.position.distance(to: system.listener.position)
        let gain = groups.reduce(s.gainDB) { $0 + $1.gainDB } + (s.distance?.levelDB(at: d) ?? 0)
        let mute = s.mute || groups.contains { $0.mute }
        var c = SourceConfig(input: s.input, name: s.name, position: s.position, gainDB: gain, mute: mute,
                            width: s.width, groups: sends, lfeDB: system.lfeMode == .equal ? lfeSend : nil,
                            eq: s.eq, compressor: s.compressor, trimDB: s.trimDB, invert: s.invert, delayMS: s.delayMS,
                            link: stereoPartner(of: s.id).flatMap { source($0)?.input })
        if let air = s.distance?.airDB(at: d), air < 0 { c.airDB = air }
        // The reverb send has the source's and its groups' levels but no distance modelling.
        if let r = s.reverb, let id = r.room, let k = show.rooms.firstIndex(where: { $0.id == id }) {
            let base = groups.reduce(s.gainDB) { $0 + $1.gainDB }
            c.reverb = SourceReverbConfig(room: k, sendDB: base + r.sendDB, earlyDB: r.early ? base + r.earlyDB : nil)
        }
        return c
    }

    /// The rooms as the renderer takes them: in the show's order (a source's room is its index), each
    /// on its speakers (all but the LFE ones, unless it uses a subset).
    public func roomConfigs() -> [RoomConfig] {
        let listener = system.listener.position
        let all = system.speakers.filter { !system.lfeSpeakers.contains($0.id) }.map(\.output)
        return show.rooms.map { r in
            let centre = r.centre ?? Position(listener.x, listener.y, 0)
            let outputs = r.useSpeakerSubset ? r.speakers.compactMap { speaker($0)?.output } : all
            return RoomConfig(name: r.name, on: !r.mute,
                              low: Position(centre.x - r.width / 2, centre.y - r.depth / 2, centre.z),
                              high: Position(centre.x + r.width / 2, centre.y + r.depth / 2, centre.z + r.height),
                              decayS: r.decayS, lowDecay: r.lowDecay, highDecay: r.highDecay, predelayMS: r.predelayMS,
                              levelDB: r.levelDB, earlyDB: r.earlyDB, absorption: r.absorption, diffusion: r.diffusion,
                              modulation: r.modulation, speakers: outputs.sorted(), listener: listener)
        }
    }

    /// The engine's settings with this show's speakers, groups and sources in place of engine.json's.
    /// Sources keep the show's order, so source i here is show.sources[i].
    public func engineConfig(base: EngineConfig) -> EngineConfig {
        var c = base
        var outputOf: [UUID: Int] = [:]
        for s in system.speakers { outputOf[s.id] = s.output }
        c.speakers = system.speakers.map(\.config)
        // Left to right as the listener faces, in plan, for Pan groups.
        let right = system.listener.point(Polar(azimuth: -90, elevation: 0, distance: 1))
        let l = system.listener.position
        let axis = Position(right.x - l.x, right.y - l.y, 0)
        c.groups = show.groups.filter(isPlayable).map { g -> GroupConfig in
            var weights: [String: Double] = [:]
            for (key, db) in g.weightsDB {
                if let id = UUID(uuidString: key), let o = outputOf[id] { weights[String(o)] = db }
            }
            var config = GroupConfig(name: g.name, renderer: g.renderer,
                               speakers: g.speakers.compactMap { outputOf[$0] }.map(String.init).joined(separator: ", "),
                               gainDB: g.gainDB, weightsDB: weights, precedenceMS: g.precedenceMS, rolloff: g.rolloff,
                               referenceDistance: g.referenceDistance, distanceOffset: g.distanceOffset,
                               // Directional panners pan around it; every algorithm spreads around it.
                               reference: g.reference ?? system.listener.position,
                               dimensions: g.dimensions, blur: g.blur, rolloffDB: g.rolloffDB, neighbours: g.neighbours,
                               spread: g.spread, tightness: g.tightness, panLawDB: g.panLawDB)
            config.panAxis = axis
            return config
        }
        let lfe = system.lfeSpeakers.compactMap { outputOf[$0] }
        if system.lfeMode == .equal {
            c.lfeOutputs = lfe.isEmpty ? nil : lfe.map(String.init).joined(separator: ", ")
        } else {
            // The subs as a group of their own, which the sources' LFE sends play through.
            c.lfeOutputs = nil
            if !lfe.isEmpty {
                let renderer: Renderer = system.lfeMode == .delay ? .delay : (system.lfeMode == .pan ? .pan : .dbap)
                var sub = GroupConfig(name: Self.lfeGroupName, renderer: renderer,
                                      speakers: lfe.map(String.init).joined(separator: ", "),
                                      reference: system.listener.position)
                sub.panAxis = axis
                c.groups.append(sub)
            }
        }
        // With no group to play through (none yet, the last deleted, or none with enough speakers),
        // the sources play nothing rather than fail the layout.
        c.sources = c.groups.isEmpty ? [] : show.sources.map(sourceConfig)
        c.rooms = roomConfigs()
        return c
    }

    /// The name the LFE group goes by in the renderer when it is a Delay or DBAP group.
    public static let lfeGroupName = "LFE (subs)"

    /// A show made from engine.json's speakers, groups and sources (milestone 2's layout keys).
    public static func importing(_ config: EngineConfig, name: String) throws -> ShowState {
        var speakers = config.speakers.map {
            Speaker(number: $0.output, name: $0.name, output: $0.output, position: $0.position, delayMS: $0.delayMS,
                    trimDB: $0.trimDB, invert: $0.invert, mute: $0.mute, eq: $0.eq, limiterDB: $0.limiterDB,
                    limiterReleaseMS: $0.limiterReleaseMS)
        }
        func speakerID(output: Int) -> UUID {
            if let s = speakers.first(where: { $0.output == output }) { return s.id }
            // An LFE output with no speaker: add one at the stage centre so it can be listed.
            let s = Speaker(number: output, name: "LFE \(output)", output: output, position: Position(0, 0, 0), type: "sub")
            speakers.append(s)
            return s.id
        }
        var groups: [SpeakerGroup] = []
        for (i, g) in config.groups.enumerated() {
            let outs = try Routing.channelList(g.speakers, limit: config.outputs, side: "output")
            let ids = outs.map { speakerID(output: $0) }
            var weights: [String: Double] = [:]
            for (key, db) in g.weightsDB { if let o = Int(key), let k = outs.firstIndex(of: o) { weights[ids[k].uuidString] = db } }
            groups.append(SpeakerGroup(number: i + 1, name: g.name, renderer: g.renderer, speakers: ids, gainDB: g.gainDB,
                                       weightsDB: weights, precedenceMS: g.precedenceMS, rolloff: g.rolloff,
                                       referenceDistance: g.referenceDistance, distanceOffset: g.distanceOffset,
                                       reference: g.reference, dimensions: g.dimensions, blur: g.blur, rolloffDB: g.rolloffDB,
                                       neighbours: g.neighbours, spread: g.spread, tightness: g.tightness))
        }
        let lfe = try config.lfeOutputs.map { try Routing.channelList($0, limit: config.outputs, side: "output") } ?? []
        let lfeIDs = lfe.map { speakerID(output: $0) }
        let sources = config.sources.enumerated().map { i, s -> Source in
            // No groups listed meant every group at 0 dB.
            let sends = s.groups.map { named -> [GroupSend] in
                groups.filter { named[$0.name] != nil }.map { GroupSend(group: $0.id, gainDB: named[$0.name]!) }
            } ?? groups.map { GroupSend(group: $0.id) }
            return Source(number: i + 1, name: s.name, input: s.input, position: s.position, gainDB: s.gainDB, mute: s.mute,
                          width: s.width, sends: sends, lfeDB: s.lfeDB)
        }
        let state = ShowState(show: Show(name: name, sources: sources, groups: groups),
                              system: SystemLayer(speakers: speakers, lfeSpeakers: lfeIDs))
        try state.validate()
        return state
    }
}

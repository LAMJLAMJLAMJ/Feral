#if canImport(SwiftUI) && os(macOS)
import FeralControl
import FeralScene
import Foundation
import SwiftUI

/// The app's copy of the engine's show, kept in step over the control link. Every change the app
/// makes is a request to the engine; the show here only changes when the engine says it applied one,
/// so the app always shows what the engine is playing. Everything runs on the main queue.
final class EngineModel: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var state: ShowState?
    @Published private(set) var status: EngineStatus?
    /// The engine's last refusal or error, shown until dismissed.
    @Published var lastError: String?
    @Published private(set) var address = ""
    /// The engine's host, for OSC test messages.
    private(set) var host = "127.0.0.1"
    /// Levels, 20 times a second. Kept apart so meters redraw without the rest of the window.
    let meters = MeterStore()
    /// The spectrum of the source whose EQ or compressor is open.
    let spectrum = SpectrumStore()
    /// Open views wanting each input's spectrum (from 1), newest last.
    private var spectrumWanted: [Int] = []
    /// The OSC and MIDI the engine hears, and test messages the app sends.
    let monitor = ControlMonitor()
    /// The engine's launchd agent on this Mac: start, stop, start at login.
    let service = EngineService()
    /// The audio devices on the engine's Mac, and engine.json's `device`.
    @Published private(set) var devices: [AudioDeviceSummary] = []
    @Published private(set) var selectedDevice: String?
    /// A device chosen in a menu, waiting for the person to confirm the switch.
    @Published var pendingDevice: AudioDeviceSummary?
    private var deviceTimer: Timer?
    /// The patch between the sound card's channels and the engine's inputs and outputs.
    @Published private(set) var patch: PatchInfo?

    private var mirror = MirroredShow()
    private var client: ControlClient?

    func connect(host: String, port: Int) {
        client?.stop()
        mirror = MirroredShow()
        state = nil
        status = nil
        meters.reset()
        self.host = host
        address = "\(host):\(port)"
        let c = ControlClient(host: host, port: port, name: "Feral app", queue: .main)
        c.onEvent = { [weak self] event in self?.handle(event) }
        c.onConnected = { [weak self] up in
            guard let self else { return }
            self.connected = up
            if up {
                // Meters and the control monitor are off until a client asks.
                self.client?.send(.watch(meters: true, activity: true))
                self.client?.send(.listDevices)
                self.client?.send(.getPatch)
                if let input = self.spectrumWanted.last { self.client?.send(.analyse(input: input)) }
            } else {
                self.state = nil; self.status = nil; self.mirror = MirroredShow()
                self.meters.reset()
            }
        }
        c.start()
        client = c
        deviceTimer?.invalidate()
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.connected else { return }
            self.refreshDevices()
        }
    }

    private func handle(_ event: Event) {
        if !mirror.handle(event) { client?.send(.refresh) }
        switch event {
        case .state, .applied:
            state = mirror.state
            status = mirror.status
        case .status:
            status = mirror.status
        case .error(let message):
            lastError = message
        case .meters(let frame):
            meters.update(frame)
        case .activity(let lines, let dropped):
            monitor.heard(lines, dropped: dropped)
        case .devices(let list, let selected):
            if devices != list { devices = list }
            if selectedDevice != selected { selectedDevice = selected }
        case .patch(let p):
            if patch != p { patch = p; meters.patch = p }
        case .spectrum(let frame):
            spectrum.update(frame)
        }
    }

    /// The device engine.json names, if it is on the engine's Mac now.
    var currentDevice: AudioDeviceSummary? { devices.first { $0.matches(selectedDevice) } }

    /// Asks again for the device list (cards come and go).
    func refreshDevices() { send(.listDevices) }

    func setDevice(_ device: AudioDeviceSummary) { send(.setDevice(device: device.uid)) }

    func refreshPatch() { send(.getPatch) }

    func setPatch(inputs: [Int]?, outputs: [Int]?, monitor: [Int]? = nil) {
        send(.setPatch(inputs: inputs, outputs: outputs, monitor: monitor))
    }

    func setChannelCounts(inputs: Int?, outputs: Int?) { send(.setChannelCounts(inputs: inputs, outputs: outputs)) }

    func send(_ request: Request) { client?.send(request) }

    /// A view showing input n's spectrum appeared: the engine analyses the newest one wanted.
    func wantSpectrum(input n: Int) {
        spectrumWanted.append(n)
        send(.analyse(input: n))
    }

    /// That view went away.
    func dropSpectrum(input n: Int) {
        if let i = spectrumWanted.lastIndex(of: n) { spectrumWanted.remove(at: i) }
        send(.analyse(input: spectrumWanted.last))
        if spectrumWanted.isEmpty { spectrum.clear() }
    }
    func apply(_ command: Command) { send(.apply(command: command)) }

    func update(_ source: UUID, _ values: SourceValues) {
        apply(.updateSources(updates: [SourceUpdate(id: source, values: values)]))
    }

    func go(_ cue: String? = nil) { send(.go(cue: cue)) }

    /// Feral's input count, from the patch (or the meters) when the engine has sent them.
    var feralInputs: Int { patch?.inputs.count ?? (meters.inputs.isEmpty ? 128 : meters.inputs.count) }

    /// Adds a source on the first Feral input no source uses. A copy (`like`) takes the original's
    /// sends, level, width and LFE send, a little to its right; a new one sends to every group at
    /// 0 dB, like the last source if there is one. Returns its id.
    @discardableResult
    func addSource(like original: Source? = nil) -> UUID? {
        guard let state else { return nil }
        let used = Set(state.show.sources.map(\.input))
        guard let input = (1...max(feralInputs, 1)).first(where: { !used.contains($0) }) else {
            lastError = "Every Feral input (\(feralInputs)) already has a source."
            return nil
        }
        let number = (state.show.sources.map(\.number).max() ?? 0) + 1
        let base = original ?? state.show.sources.last
        var position = Position(0, 4, 1.5)
        if let p = base?.position { position = Position(p.x + 1, p.y, p.z) }
        var source = Source(number: number, input: input, position: position,
                            sends: base?.sends ?? state.show.groups.map { GroupSend(group: $0.id) })
        if let original {
            source.name = (original.name ?? "Source \(original.number)") + " copy"
            source.gainDB = original.gainDB
            source.width = original.width
            source.lfeDB = original.lfeDB
        }
        apply(.setSource(source: source))
        return source.id
    }

    /// Moves a source to another Feral input, if no other source uses it.
    func setInput(_ input: Int, of source: Source) {
        guard let state, input != source.input else { return }
        guard (1...max(feralInputs, 1)).contains(input) else {
            lastError = "Feral inputs run from 1 to \(feralInputs)."
            return
        }
        if let other = state.show.sources.first(where: { $0.input == input && $0.id != source.id }) {
            lastError = "Source \(other.label) already uses Feral input \(input)."
            return
        }
        var s = source
        s.input = input
        apply(.setSource(source: s))
    }

    func recall(_ snapshot: Snapshot, fadeSeconds: Double? = nil) {
        send(.recall(snapshot: snapshot.id.uuidString, fadeSeconds: fadeSeconds))
    }

    /// Stores every source, every field, as a new snapshot; returns its id.
    @discardableResult
    func storeSnapshot() -> UUID? {
        guard let state else { return nil }
        let n = state.nextSnapshotNumber
        let capture = SnapshotCapture(number: n, name: "Snapshot \(n)")
        apply(.captureSnapshot(capture: capture))
        return capture.id
    }

    /// Stores the sources' values again into an existing snapshot, keeping its scope of sources and fields.
    func restore(_ snapshot: Snapshot) {
        let fields = state.map { Array($0.fields(of: snapshot)) } ?? []
        apply(.captureSnapshot(capture: SnapshotCapture(
            id: snapshot.id, number: snapshot.number, name: snapshot.name, sources: snapshot.sources.map(\.id),
            fields: fields.isEmpty ? nil : SnapshotField.allCases.filter(fields.contains),
            fadeSeconds: snapshot.fadeSeconds, curve: snapshot.curve)))
    }

    /// Adds a cue at the end of the list for a snapshot; returns its id.
    @discardableResult
    func addCue(for snapshot: Snapshot?) -> UUID? {
        guard let state else { return nil }
        let cue = Cue(number: state.nextCueNumber, name: snapshot?.name, snapshot: snapshot?.id)
        apply(.setCue(cue: cue))
        return cue.id
    }

    func save() { send(.save) }

    // MARK: Source groups

    /// Makes a source group, with some sources in it; returns its id.
    @discardableResult
    func addSourceGroup(with sources: [UUID] = []) -> UUID? {
        guard let state else { return nil }
        let n = state.nextSourceGroupNumber
        let group = SourceGroup(number: n, name: "Group \(n)", sources: sources)
        apply(.setSourceGroup(group: group))
        return group.id
    }

    func setSourceGroup(_ group: SourceGroup) { apply(.setSourceGroup(group: group)) }

    /// Adds an output (speaker) group with these speakers; returns its id. It starts as Delay, or as
    /// VBAP when one of the speakers is already in a Delay group (a speaker can be in one only).
    /// Feral's outputs (speaker outputs, not counting Binaural L and R).
    var feralOutputs: Int { patch?.outputs.count ?? (meters.outputs.isEmpty ? 128 : meters.outputs.count) }

    /// Adds a speaker on the lowest free Feral output, a metre to the right of the last one (or 5 m
    /// in front of the listener), in no group yet. Returns its id.
    func addSpeaker() -> UUID? {
        guard let state else { return nil }
        let used = Set(state.system.speakers.map(\.output))
        guard let output = (1...max(feralOutputs, 1)).first(where: { !used.contains($0) }) else {
            lastError = "Every Feral output (\(feralOutputs)) already has a speaker. Add outputs in Audio > Patch (Outputs, the count at the top right)."
            return nil
        }
        let n = (state.system.speakers.map(\.number).max() ?? 0) + 1
        let last = state.system.speakers.max { $0.number < $1.number }
        let position = last.map { Position($0.position.x + 1, $0.position.y, $0.position.z) }
            ?? state.point(Polar(azimuth: 0, elevation: 0, distance: 5))
        let speaker = Speaker(number: n, output: output, position: position)
        apply(.setSpeaker(speaker: speaker))
        return speaker.id
    }

    func deleteSpeakers(_ ids: [UUID]) {
        for id in ids { apply(.removeSpeaker(id: id)) }
    }

    /// Adds a room (a hall, centred on the listener). None when the show has all it can take.
    func addRoom() -> UUID? {
        guard let state, state.show.rooms.count < Room.maxRooms else { return nil }
        let n = state.nextRoomNumber
        let room = Room(number: n, name: n == 1 ? "Hall" : "Room \(n)").with(n == 1 ? .hall : .theatre)
        apply(.setRoom(room: room))
        return room.id
    }

    func addSpeakerGroup(with speakers: [UUID] = []) -> UUID? {
        guard let state else { return nil }
        let n = state.nextGroupNumber
        var name = "Group \(n)", k = 2
        while state.show.groups.contains(where: { $0.name == name }) { name = "Group \(n) (\(k))"; k += 1 }
        let inDelay = state.show.groups.contains { $0.renderer == .delay && !Set($0.speakers).isDisjoint(with: speakers) }
        let group = SpeakerGroup(number: n, name: name, renderer: inDelay ? .vbap : .delay, speakers: sortedSpeakers(speakers))
        apply(.setGroup(group: group))
        return group.id
    }

    /// Puts speakers in an output group, or takes them out (with their trims in it).
    func setSpeakers(_ speakers: [UUID], of group: SpeakerGroup, _ member: Bool) {
        var g = group
        if member {
            g.speakers = sortedSpeakers(g.speakers + speakers.filter { !g.speakers.contains($0) })
        } else {
            g.speakers.removeAll { speakers.contains($0) }
            for id in speakers { g.weightsDB[id.uuidString] = nil }
        }
        if g != group { apply(.setGroup(group: g)) }
    }

    /// In speaker-number order.
    private func sortedSpeakers(_ ids: [UUID]) -> [UUID] {
        guard let state else { return ids }
        return ids.sorted { (state.speaker($0)?.number ?? 0) < (state.speaker($1)?.number ?? 0) }
    }

    func setMember(_ source: UUID, of group: SourceGroup, _ member: Bool) { setMembers([source], of: group, member) }

    /// Puts several sources in a group, or takes them out.
    func setMembers(_ sources: [UUID], of group: SourceGroup, _ member: Bool) {
        // A stereo pair goes in or out of a group as one.
        let sources = withStereoPartners(sources)
        var g = group
        g.sources.removeAll { sources.contains($0) }
        if member, let state {
            g.sources.append(contentsOf: sources)
            // Keep the show's order of sources.
            let order = state.show.sources.map(\.id)
            g.sources.sort { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
        }
        setSourceGroup(g)
    }

    /// These sources and the other side of any stereo pair among them, in the show's order.
    func withStereoPartners(_ ids: [UUID]) -> [UUID] {
        guard let state else { return ids }
        var all = Set(ids)
        for id in ids { if let p = state.stereoPartner(of: id) { all.insert(p) } }
        return state.show.sources.map(\.id).filter { all.contains($0) }
    }

    /// The stereo pair a source is a side of: the pair's group, its left and right.
    func stereoPair(of source: UUID) -> (group: SourceGroup, left: Source, right: Source)? {
        guard let state, let g = state.show.sourceGroups.first(where: { $0.stereo && $0.sources.prefix(2).contains(source) }),
              let pair = state.stereoPair(g) else { return nil }
        return (g, pair.left, pair.right)
    }

    /// Deletes sources; a stereo pair goes as a whole, its pairing with it.
    func deleteSources(_ ids: [UUID]) {
        guard let state else { return }
        let all = withStereoPartners(ids)
        let pairs = state.show.sourceGroups.filter { g in g.stereo && g.sources.prefix(2).allSatisfy { all.contains($0) } }
        for id in all { apply(.removeSource(id: id)) }
        for g in pairs { apply(.removeSourceGroup(id: g.id)) }
    }

    /// Adds a stereo source: a left and a right source on two free Feral inputs (side by side when it
    /// can), 30° apart straight ahead of the listener, in a paired stereo group. Returns the group's id.
    @discardableResult
    func addStereoSource() -> UUID? {
        guard let state else { return nil }
        let used = Set(state.show.sources.map(\.input))
        let count = max(feralInputs, 1)
        let free = (1...count).filter { !used.contains($0) }
        guard free.count >= 2 else {
            lastError = "A stereo source needs two free Feral inputs; raise the count in Audio > Patch."
            return nil
        }
        let pair = free.first { free.contains($0 + 1) }.map { ($0, $0 + 1) } ?? (free[0], free[1])
        let n = state.nextSourceGroupNumber
        let number = (state.show.sources.map(\.number).max() ?? 0) + 1
        let sends = state.show.sources.last?.sends ?? state.show.groups.map { GroupSend(group: $0.id) }
        let ahead = state.polar(of: state.system.listener.position).elevation  // 0; keeps the listener's height
        let left = Source(number: number, name: "Stereo \(n) L", input: pair.0,
                          position: state.point(Polar(azimuth: 15, elevation: ahead, distance: 5)), sends: sends)
        let right = Source(number: number + 1, name: "Stereo \(n) R", input: pair.1,
                           position: state.point(Polar(azimuth: -15, elevation: ahead, distance: 5)), sends: sends)
        apply(.setSource(source: left))
        apply(.setSource(source: right))
        let group = SourceGroup(number: n, name: "Stereo \(n)", sources: [left.id, right.id], stereo: true)
        apply(.setSourceGroup(group: group))
        return group.id
    }

    /// Spreads a stereo pair to a new spacing in degrees.
    func setSpacing(_ group: SourceGroup, _ degrees: Double) {
        guard let state else { return }
        let updates = state.setSpacing(group, to: degrees)
        if !updates.isEmpty { apply(.updateSources(updates: updates)) }
    }

    /// Moves a group's centre to a new azimuth, elevation or distance, keeping its shape.
    func moveGroup(_ group: SourceGroup, azimuth: Double? = nil, elevation: Double? = nil, distance: Double? = nil) {
        guard let state else { return }
        let updates = state.moveGroup(group, azimuth: azimuth, elevation: elevation, distance: distance)
        if !updates.isEmpty { apply(.updateSources(updates: updates)) }
    }

    /// Where a dragged source's linked partners start, for moving them with it.
    func dragPartners(of source: UUID) -> [UUID: Position] {
        guard let state else { return [:] }
        var starts: [UUID: Position] = [:]
        for id in state.linkedPartners(of: source) { if let s = state.source(id) { starts[id] = s.position } }
        return starts
    }

    /// Turns a dragged source and its linked partners round the listener by `turn` degrees of azimuth
    /// and raises them by `raise` degrees of elevation, from where they started; distances stay.
    func dragPolar(_ source: UUID, start: Position, turn: Double, raise: Double, partners: [UUID: Position]) {
        guard let state else { return }
        var starts = partners
        starts[source] = start
        let updates = starts.compactMap { id, p -> SourceUpdate? in
            guard state.source(id) != nil else { return nil }
            var v = state.polar(of: p)
            guard v.distance > 0 else { return nil }
            v.azimuth += turn
            v.elevation = min(max(v.elevation + raise, -90), 90)
            return SourceUpdate(id: id, values: SourceValues(position: state.point(v)))
        }
        if !updates.isEmpty { apply(.updateSources(updates: updates)) }
    }

    /// Moves a dragged source, and its linked partners by the same amount.
    /// Puts sources (a stereo pair's both sides) on their nearest speakers.
    func snapToNearestSpeakers(_ sources: [UUID]) {
        guard let state else { return }
        let updates = state.snappedToNearestSpeakers(withStereoPartners(sources))
        if !updates.isEmpty { apply(.updateSources(updates: updates)) }
    }

    func drag(_ source: UUID, from: Position, to: Position, partners: [UUID: Position]) {
        guard let state else { return }
        if partners.isEmpty {
            update(source, SourceValues(position: to))
        } else {
            apply(.updateSources(updates: state.moveTogether(source, from: from, to: to, starts: partners)))
        }
    }
}

/// What is selected, in the sidebar or on the plan.
enum Selection: Hashable {
    case source(UUID), speaker(UUID), snapshot(UUID), cue(UUID), sourceGroup(UUID), speakerGroup(UUID), listener, binaural, lfe
    case room(UUID)
}

extension Color {
    /// "#RRGGBB".
    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    static let palette: [Color] = [
        Color(red: 0.95, green: 0.42, blue: 0.30), Color(red: 0.25, green: 0.62, blue: 0.95),
        Color(red: 0.36, green: 0.78, blue: 0.42), Color(red: 0.96, green: 0.74, blue: 0.22),
        Color(red: 0.70, green: 0.45, blue: 0.95), Color(red: 0.20, green: 0.80, blue: 0.80),
        Color(red: 0.95, green: 0.40, blue: 0.70), Color(red: 0.60, green: 0.65, blue: 0.70),
    ]

    static func pick(_ n: Int) -> Color { palette[((n - 1) % palette.count + palette.count) % palette.count] }
}

extension Source {
    var color: Color { Color(hex: colour) ?? .pick(number) }
}

extension SourceGroup {
    var color: Color { Color(hex: colour) ?? .pick(number + 5) }
}

extension SpeakerGroup {
    var color: Color { Color(hex: colour) ?? .pick(number + 3) }
}

extension Double {
    /// "1.5" or "-3", for labels.
    var short: String { self == rounded() ? String(Int(self)) : String(format: "%.2f", self) }
}
#endif

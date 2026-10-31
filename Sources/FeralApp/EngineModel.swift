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

    private var mirror = MirroredShow()
    private var client: ControlClient?

    func connect(host: String, port: Int) {
        client?.stop()
        mirror = MirroredShow()
        state = nil
        status = nil
        address = "\(host):\(port)"
        let c = ControlClient(host: host, port: port, name: "Feral app", queue: .main)
        c.onEvent = { [weak self] event in self?.handle(event) }
        c.onConnected = { [weak self] up in
            guard let self else { return }
            self.connected = up
            if !up { self.state = nil; self.status = nil; self.mirror = MirroredShow() }
        }
        c.start()
        client = c
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
        }
    }

    func send(_ request: Request) { client?.send(request) }
    func apply(_ command: Command) { send(.apply(command: command)) }

    func update(_ source: UUID, _ values: SourceValues) {
        apply(.updateSources(updates: [SourceUpdate(id: source, values: values)]))
    }

    func go(_ cue: String? = nil) { send(.go(cue: cue)) }

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

    /// Stores the sources' values again into an existing snapshot, keeping its scope of sources.
    func restore(_ snapshot: Snapshot) {
        apply(.captureSnapshot(capture: SnapshotCapture(
            id: snapshot.id, number: snapshot.number, name: snapshot.name, sources: snapshot.sources.map(\.id),
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
}

/// What is selected, in the sidebar or on the plan.
enum Selection: Hashable {
    case source(UUID), speaker(UUID), snapshot(UUID), cue(UUID)
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

extension SpeakerGroup {
    var color: Color { Color(hex: colour) ?? .pick(number + 3) }
}

extension Double {
    /// "1.5" or "-3", for labels.
    var short: String { self == rounded() ? String(Int(self)) : String(format: "%.2f", self) }
}
#endif

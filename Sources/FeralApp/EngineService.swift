#if canImport(SwiftUI) && os(macOS)
import Foundation
import SwiftUI

/// The engine's launchd agent on this Mac (installed by scripts/install-engine.sh): whether it runs,
/// and starting, stopping and restarting it, and whether it starts at login. It drives launchctl as
/// scripts/engine.sh does, so the engine still runs under launchd (and is restarted if it crashes)
/// whoever started it. Only for an engine on this Mac.
final class EngineService: ObservableObject {
    enum AgentState: Equatable {
        case unknown
        /// No agent in ~/Library/LaunchAgents: run scripts/install-engine.sh.
        case notInstalled
        /// Installed but not loaded in launchd (turned off, or stopped with bootout).
        case unloaded
        case stopped
        case running(pid: Int)

        var text: String {
            switch self {
            case .unknown: return "checking…"
            case .notInstalled: return "not installed on this Mac"
            case .unloaded: return "off"
            case .stopped: return "stopped"
            case .running(let pid): return "running (pid \(pid))"
            }
        }

        var isRunning: Bool { if case .running = self { return true } else { return false } }
    }

    static let label = "local.feral.engine"

    @Published private(set) var state = AgentState.unknown
    /// The agent is enabled, so launchd starts the engine at login.
    @Published private(set) var startsAtLogin = false
    @Published private(set) var busy = false
    /// The last launchctl failure, shown until dismissed.
    @Published var lastError: String?

    private let queue = DispatchQueue(label: "feral.app.launchctl")
    private var timer: Timer?
    private var domain: String { "gui/\(getuid())" }
    private var target: String { "\(domain)/\(Self.label)" }
    private var plist: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.label).plist").path
    }

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        queue.async { [self] in
            let (s, login) = read()
            DispatchQueue.main.async {
                if self.state != s { self.state = s }
                if self.startsAtLogin != login { self.startsAtLogin = login }
            }
        }
    }

    /// Starts the engine. A turned-off agent is loaded again; whether it starts at login stays as it was.
    func start() {
        run("start the engine") { [self] in
            guard FileManager.default.fileExists(atPath: plist) else { throw ServiceError(AgentState.notInstalled.text) }
            if launchctl(["print", target]).status == 0 {
                try check(launchctl(["kickstart", target]))
            } else {
                // A disabled agent will not load, so enable it to load it, then put the setting back.
                let wasDisabled = isDisabled()
                if wasDisabled { try check(launchctl(["enable", target])) }
                defer { if wasDisabled { _ = launchctl(["disable", target]) } }
                try check(launchctl(["bootstrap", domain, plist]))
            }
        }
    }

    /// Stops the engine cleanly. launchd leaves it stopped until Start or the next login.
    func stop() {
        run("stop the engine") { [self] in
            guard launchctl(["print", target]).status == 0 else { return }
            try check(launchctl(["kill", "SIGTERM", target]))
        }
    }

    func restart() {
        run("restart the engine") { [self] in
            if launchctl(["print", target]).status == 0 {
                try check(launchctl(["kickstart", "-k", target]))
            } else {
                DispatchQueue.main.async { self.start() }
            }
        }
    }

    /// Re-reads engine.json without stopping (as engine.sh reload).
    func reload() {
        run("reload the settings") { [self] in try check(launchctl(["kill", "SIGHUP", target])) }
    }

    func setStartsAtLogin(_ on: Bool) {
        run(on ? "turn on start at login" : "turn off start at login") { [self] in
            try check(launchctl([on ? "enable" : "disable", target]))
        }
    }

    // MARK: launchctl

    private struct ServiceError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    private func run(_ what: String, _ work: @escaping () throws -> Void) {
        busy = true
        queue.async { [self] in
            var failure: String?
            do { try work() } catch { failure = "Could not \(what): \(error)" }
            let (s, login) = read()
            DispatchQueue.main.async {
                self.busy = false
                self.state = s
                self.startsAtLogin = login
                if let failure { self.lastError = failure }
            }
        }
    }

    private func read() -> (AgentState, Bool) {
        guard FileManager.default.fileExists(atPath: plist) else { return (.notInstalled, false) }
        let login = !isDisabled()
        let p = launchctl(["print", target])
        guard p.status == 0 else { return (.unloaded, login) }
        for line in p.output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("pid = "), let pid = Int(t.dropFirst("pid = ".count)) { return (.running(pid: pid), login) }
        }
        return (.stopped, login)
    }

    /// launchctl print-disabled lists `"local.feral.engine" => disabled` (or `=> true` on older macOS).
    private func isDisabled() -> Bool {
        launchctl(["print-disabled", domain]).output.split(separator: "\n").contains { line in
            line.contains("\"\(Self.label)\"") && (line.contains("disabled") || line.contains("true"))
        }
    }

    private func check(_ r: (status: Int32, output: String)) throws {
        guard r.status == 0 else {
            let text = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ServiceError(text.isEmpty ? "launchctl failed (\(r.status))" : text)
        }
    }

    private func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Start, Stop, Restart and Start at login, for the sidebar, the waiting screen and the Engine menu.
struct EngineControls: View {
    @ObservedObject var service: EngineService
    let local: Bool

    var body: some View {
        if !local {
            Text("The engine is on another Mac; start and stop it there.").foregroundStyle(.secondary)
        } else if service.state == .notInstalled {
            Text("The engine is not installed on this Mac. In Terminal, in the Feral folder: ./scripts/install-engine.sh")
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                if service.state.isRunning {
                    Button("Stop") { service.stop() }
                    Button("Restart") { service.restart() }
                } else {
                    Button("Start engine") { service.start() }.buttonStyle(.borderedProminent)
                }
                Toggle("Start at login", isOn: Binding(get: { service.startsAtLogin }, set: { service.setStartsAtLogin($0) }))
                    .toggleStyle(.checkbox)
                if service.busy { ProgressView().controlSize(.small) }
            }
            .disabled(service.busy)
        }
    }
}

/// The menu bar's Engine menu.
struct EngineMenu: View {
    @ObservedObject var service: EngineService
    @AppStorage("engineHost") private var host = "127.0.0.1"

    var body: some View {
        let local = EngineService.isLocal(host)
        Button("Start engine") { service.start() }
            .disabled(!local || service.state.isRunning || service.state == .notInstalled)
        Button("Stop engine") { service.stop() }
            .disabled(!local || !service.state.isRunning)
        Button("Restart engine") { service.restart() }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(!local || service.state == .notInstalled)
        Button("Reload engine.json") { service.reload() }
            .disabled(!local || !service.state.isRunning)
        Divider()
        Toggle("Start engine at login", isOn: Binding(get: { service.startsAtLogin }, set: { service.setStartsAtLogin($0) }))
            .disabled(!local || service.state == .notInstalled)
    }
}

/// "Engine: running (pid 412)" with Start/Stop, at the top of the sidebar's status.
struct EngineServiceRow: View {
    @ObservedObject var service: EngineService
    let local: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(service.state.isRunning ? Color.green : Color.red).frame(width: 7, height: 7)
            Text("Engine").bold().frame(width: 38, alignment: .leading)
            Text(local ? service.state.text : "on another Mac").foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            if local && service.state != .notInstalled {
                if service.state.isRunning {
                    Button("Stop") { service.stop() }.help("Stop the engine (it stays stopped until Start or the next login)")
                } else {
                    Button("Start") { service.start() }.help("Start the engine")
                }
            }
        }
        .buttonStyle(.borderless)
        .disabled(service.busy)
    }
}

/// The engine's state on the waiting screen.
struct EngineStateLine: View {
    @ObservedObject var service: EngineService
    let local: Bool

    var body: some View {
        if local { Text("Engine on this Mac: \(service.state.text)").font(.callout).foregroundStyle(.secondary) }
    }
}

/// Shows a failed start or stop.
struct ServiceAlert: ViewModifier {
    @ObservedObject var service: EngineService

    func body(content: Content) -> some View {
        content.alert("The engine could not be changed", isPresented: Binding(get: { service.lastError != nil },
                                                                              set: { if !$0 { service.lastError = nil } })) {
            Button("OK") { service.lastError = nil }
        } message: {
            Text(service.lastError ?? "")
        }
    }
}

extension EngineService {
    /// The app reaches the engine on this Mac.
    static func isLocal(_ host: String) -> Bool { ["127.0.0.1", "localhost", "::1"].contains(host) }
}
#endif

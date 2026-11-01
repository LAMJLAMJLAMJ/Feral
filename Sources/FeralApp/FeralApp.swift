#if canImport(SwiftUI) && os(macOS)
import AppKit
import FeralControl
import FeralScene
import SwiftUI

struct FeralApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = EngineModel()
    @AppStorage("engineHost") private var host = "127.0.0.1"
    @AppStorage("enginePort") private var port = defaultControlPort

    var body: some Scene {
        WindowGroup("Feral") {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 620)
                .onAppear { model.connect(host: host, port: port) }
        }
        Settings {
            SettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as a normal app with a Dock icon and menu bar, also when started with `swift run`.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Feral > Settings: which engine to connect to.
struct SettingsView: View {
    @ObservedObject var model: EngineModel
    @AppStorage("engineHost") private var host = "127.0.0.1"
    @AppStorage("enginePort") private var port = defaultControlPort

    var body: some View {
        Form {
            TextField("Engine address", text: $host)
            TextField("Port", value: $port, format: .number.grouping(.never))
            Text("127.0.0.1 is the engine on this Mac. For an engine on another Mac, set its engine.json "
                 + "controlAddress to 0.0.0.0 and enter that Mac's IP address here.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Connect") { model.connect(host: host, port: port) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct ContentView: View {
    @ObservedObject var model: EngineModel
    @State private var selection: Selection?
    @State private var moveSpeakers = false

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let state = model.state {
                HStack(spacing: 0) {
                    PlanView(model: model, state: state, selection: $selection, moveSpeakers: moveSpeakers)
                    Divider()
                    InspectorView(model: model, state: state, selection: $selection)
                        .frame(width: 300)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(model.connected ? "Loading the show…" : "Waiting for feral-engine at \(model.address)")
                    Text("Is the engine running? In Terminal: ./scripts/engine.sh status. "
                         + "Feral > Settings sets the engine's address.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(model.state?.show.name ?? "Feral")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $moveSpeakers) { Label("Move speakers", systemImage: "hifispeaker.2") }
                    .help("Let the plan move speakers too (the system layer)")
                Button { model.send(.stopFades) } label: { Label("Stop fades", systemImage: "stop.circle") }
                    .help("Stop every running fade where it is")
                Button { model.save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .keyboardShortcut("s", modifiers: .command)
                    .help("Save the show (⌘S)")
                    .disabled(model.state == nil)
            }
        }
        .alert("The engine refused that", isPresented: Binding(get: { model.lastError != nil },
                                                                set: { if !$0 { model.lastError = nil } })) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private var subtitle: String {
        guard model.connected, let s = model.status else { return "not connected" }
        return (s.unsaved == 0 ? "saved" : "\(s.unsaved) unsaved change(s)") + " · " + s.audio
            + (s.osc.isEmpty ? "" : " · OSC " + s.osc)
    }
}

/// The cue list, snapshots, sources and speakers.
struct SidebarView: View {
    @ObservedObject var model: EngineModel
    @Binding var selection: Selection?

    var body: some View {
        VStack(spacing: 0) {
            GoPanel(model: model)
            Divider()
            List(selection: $selection) {
                if let state = model.state {
                    Section {
                        ForEach(state.orderedCues) { cue in
                            CueRow(cue: cue, state: state, status: model.status).tag(Selection.cue(cue.id))
                        }
                    } header: {
                        HStack {
                            Text("Cues")
                            Spacer()
                            Button("Add") {
                                let snap = selectedSnapshot(state) ?? state.show.snapshots.last
                                if let id = model.addCue(for: snap) { selection = .cue(id) }
                            }
                            .buttonStyle(.borderless).font(.caption)
                            .help("Add a cue for the selected (or last) snapshot")
                        }
                    }
                    Section {
                        ForEach(state.show.snapshots.sorted { $0.number < $1.number }) { snap in
                            HStack {
                                Text(snap.label)
                                Spacer()
                                Button("Recall") { model.recall(snap) }.buttonStyle(.borderless).font(.caption)
                            }
                            .tag(Selection.snapshot(snap.id))
                        }
                    } header: {
                        HStack {
                            Text("Snapshots")
                            Spacer()
                            Button("Store") { if let id = model.storeSnapshot() { selection = .snapshot(id) } }
                                .buttonStyle(.borderless).font(.caption)
                                .help("Store every source as a new snapshot")
                        }
                    }
                    Section("Sources") {
                        ForEach(state.show.sources) { s in
                            HStack {
                                Circle().fill(s.color).frame(width: 9, height: 9)
                                Text(s.label)
                                Spacer()
                                if s.mute { Text("muted").font(.caption).foregroundStyle(.secondary) }
                                Text("in \(s.input)").font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(Selection.source(s.id))
                        }
                    }
                    Section("Speakers") {
                        ForEach(state.system.speakers.sorted { $0.number < $1.number }) { s in
                            HStack {
                                Text(s.label)
                                Spacer()
                                Text("out \(s.output)").font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(Selection.speaker(s.id))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func selectedSnapshot(_ state: ShowState) -> Snapshot? {
        if case .snapshot(let id) = selection { return state.snapshot(id) }
        return nil
    }
}

/// The big GO button with the current and next cue.
struct GoPanel: View {
    @ObservedObject var model: EngineModel

    var body: some View {
        let state = model.state
        let current = model.status?.currentCue.flatMap { state?.cue($0) }
        let next = model.status?.nextCue.flatMap { state?.cue($0) }
        VStack(alignment: .leading, spacing: 6) {
            Button { model.go() } label: {
                Text("GO").font(.title2.bold()).frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(next == nil)
            .help("Run the next cue (⌘↩)")
            Text("Current: \(current?.label ?? "none")").font(.caption)
            Text("Next: \(next?.label ?? "none")").font(.caption.bold())
        }
        .padding(10)
    }
}

struct CueRow: View {
    let cue: Cue
    let state: ShowState
    let status: EngineStatus?

    var body: some View {
        HStack {
            Image(systemName: status?.currentCue == cue.id ? "play.fill" : (status?.nextCue == cue.id ? "arrow.right" : "circle"))
                .foregroundStyle(status?.currentCue == cue.id ? .green : .secondary)
                .font(.caption)
                .frame(width: 14)
            Text(cue.label)
            Spacer()
            if cue.autoFollow { Image(systemName: "arrow.turn.down.right").font(.caption) }
            if let f = cue.fadeSeconds ?? cue.snapshot.flatMap({ state.snapshot($0) })?.fadeSeconds, f > 0 {
                Text("\(f.short) s").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
#endif

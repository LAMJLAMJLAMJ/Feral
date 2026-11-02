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
                .frame(minWidth: 1100, minHeight: 680)
                .onAppear { model.connect(host: host, port: port) }
        }
        .commands {
            CommandGroup(after: .windowArrangement) {
                OpenMonitorButton()
                OpenMixerButton()
            }
            CommandMenu("Engine") {
                EngineMenu(service: model.service)
            }
            CommandMenu("Audio") {
                AudioMenu(model: model)
            }
        }
        Window("Control monitor", id: "monitor") {
            MonitorView(model: model, monitor: model.monitor)
        }
        .defaultSize(width: 980, height: 620)
        Window("Mixer", id: "mixer") {
            MixerWindow(model: model)
        }
        .defaultSize(width: 900, height: 420)
        Window("Patch", id: "patch") {
            PatchView(model: model, meters: model.meters)
        }
        .defaultSize(width: 1100, height: 720)
        Settings {
            SettingsView(model: model)
        }
    }
}

/// Window > Control monitor (⌥⌘M).
struct OpenMonitorButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Control monitor") { openWindow(id: "monitor") }
            .keyboardShortcut("m", modifiers: [.command, .option])
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
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Selection?
    @State private var moveSpeakers = false
    @AppStorage("showMeters") private var showMeters = true
    @AppStorage("showMixer") private var showMixer = false
    @AppStorage("showHeight") private var showHeight = true
    @AppStorage("showInspector") private var showInspector = true

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, meters: model.meters, selection: $selection)
                .navigationSplitViewColumnWidth(min: 270, ideal: 310, max: 420)
        } detail: {
            // The inspector is a plain column beside the plan: SwiftUI's .inspector inside a
            // NavigationSplitView's detail left its controls unclickable on macOS.
            HStack(spacing: 0) {
                detail
                if showInspector {
                    Divider()
                    Group {
                        if let state = model.state {
                            InspectorView(model: model, meters: model.meters, state: state, selection: $selection)
                        } else {
                            Text("Not connected").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(width: 320)
                }
            }
        }
        .navigationTitle(model.state?.show.name ?? "Feral")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SoundCardPicker(model: model)
                Button { openWindow(id: "patch") } label: { Label("Patch", systemImage: "square.grid.3x3") }
                    .help("Patch the sound card's inputs and outputs to Feral's (⌥⌘P)")
                Toggle(isOn: $moveSpeakers) { Label("Move speakers", systemImage: "hifispeaker.2") }
                    .help("Let the plan move speakers too (the system layer)")
                Toggle(isOn: $showHeight) { Label("Height", systemImage: "arrow.up.and.down.square") }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .help("Show or hide the height view beside the plan (⇧⌘E)")
                Toggle(isOn: $showMixer) { Label("Mixer", systemImage: "slider.vertical.3") }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                    .help("Show or hide the mixer under the plan (⇧⌘X); Window > Mixer (⌥⌘X) opens it in its own window")
                Toggle(isOn: $showMeters) { Label("Meters", systemImage: "chart.bar.xaxis") }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .help("Show or hide the output meters above the plan (⇧⌘M)")
                Button { openWindow(id: "monitor") } label: {
                    Label("Control monitor", systemImage: "antenna.radiowaves.left.and.right")
                }
                .help("The OSC and MIDI the engine hears, and test messages to send it (⌥⌘M)")
                Button { model.save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .keyboardShortcut("s", modifiers: .command)
                    .help("Save the show (⌘S)")
                    .disabled(model.state == nil)
                Toggle(isOn: $showInspector) { Label("Inspector", systemImage: "sidebar.right") }
                    .help("Show the inspector")
            }
        }
        .alert("The engine refused that", isPresented: Binding(get: { model.lastError != nil },
                                                                set: { if !$0 { model.lastError = nil } })) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
        .modifier(ServiceAlert(service: model.service))
        .modifier(DeviceSwitchConfirmation(model: model))
    }

    @ViewBuilder
    private var detail: some View {
        if let state = model.state {
            VStack(spacing: 0) {
                // Outputs at the top, the input mixer at the bottom, so they never look alike.
                MeterBridge(meters: model.meters, state: state, selection: $selection, shown: $showMeters)
                Divider()
                HStack(spacing: 0) {
                    PlanView(model: model, meters: model.meters, state: state, selection: $selection, moveSpeakers: moveSpeakers)
                    Divider()
                    ElevationView(model: model, meters: model.meters, state: state, selection: $selection,
                                  moveSpeakers: moveSpeakers, shown: $showHeight)
                }
                Divider()
                MixerView(model: model, meters: model.meters, selection: $selection, docked: $showMixer)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text(model.connected ? "Loading the show…" : "Waiting for feral-engine at \(model.address)")
                EngineStateLine(service: model.service, local: EngineService.isLocal(model.host))
                EngineControls(service: model.service, local: EngineService.isLocal(model.host))
                Text("Feral > Settings sets the engine's address.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var subtitle: String {
        guard model.connected, let s = model.status else { return "not connected" }
        return s.unsaved == 0 ? "saved" : "\(s.unsaved) unsaved change(s)"
    }
}

/// The GO panel, then the cue list, snapshots, sources or speakers, then the engine's state.
struct SidebarView: View {
    @ObservedObject var model: EngineModel
    let meters: MeterStore
    @Binding var selection: Selection?
    @AppStorage("sidebarTab") private var tab = Tab.cues
    /// A source waiting for the person to confirm deleting it.
    @State private var deleting: Source?

    enum Tab: String, CaseIterable {
        case cues = "Cues", snapshots = "Snapshots", sources = "Sources", speakers = "Speakers"
    }

    var body: some View {
        VStack(spacing: 0) {
            GoPanel(model: model)
            Divider()
            Picker("List", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            if let state = model.state {
                listHeader(state)
                List(selection: $selection) {
                    switch tab {
                    case .cues:
                        ForEach(state.orderedCues) { cue in
                            CueRow(cue: cue, state: state, status: model.status)
                                .tag(Selection.cue(cue.id))
                                .contextMenu {
                                    Button("GO this cue") { model.go(cue.id.uuidString) }
                                    Divider()
                                    Button("Delete", role: .destructive) { model.apply(.removeCue(id: cue.id)) }
                                }
                        }
                    case .snapshots:
                        ForEach(state.show.snapshots.sorted { $0.number < $1.number }) { snap in
                            SnapshotRow(snapshot: snap) { model.recall(snap) }
                                .tag(Selection.snapshot(snap.id))
                                .contextMenu {
                                    Button("Recall over \(snap.fadeSeconds.short) s") { model.recall(snap) }
                                    Button("Recall now") { model.recall(snap, fadeSeconds: 0) }
                                    Button("Update from the sources as they are") { model.restore(snap) }
                                    Button("Add a cue for it") { if let id = model.addCue(for: snap) { selection = .cue(id) } }
                                    Divider()
                                    Button("Delete", role: .destructive) { model.apply(.removeSnapshot(id: snap.id)) }
                                }
                        }
                    case .sources:
                        if !state.show.sourceGroups.isEmpty {
                            Section("Groups") {
                                ForEach(state.show.sourceGroups) { g in
                                    SourceGroupRow(group: g, state: state)
                                        .tag(Selection.sourceGroup(g.id))
                                        .contextMenu {
                                            Button(g.mute ? "Unmute" : "Mute") { var c = g; c.mute.toggle(); model.setSourceGroup(c) }
                                            Divider()
                                            Button("Delete group", role: .destructive) {
                                                model.apply(.removeSourceGroup(id: g.id))
                                                if selection == .sourceGroup(g.id) { selection = nil }
                                            }
                                        }
                                }
                            }
                        }
                        Section {
                            ForEach(state.show.sources) { s in
                                SourceRow(source: s, owner: model.status?.owner(of: s.id) ?? .cues, meters: meters)
                                    .tag(Selection.source(s.id))
                                    .contextMenu { sourceMenu(s, state) }
                            }
                        } header: {
                            if !state.show.sourceGroups.isEmpty { Text("Sources") }
                        }
                    case .speakers:
                        let groups = groupOf(state)
                        ForEach(state.system.speakers.sorted { $0.number < $1.number }) { s in
                            SpeakerRow(speaker: s, group: groups[s.id], lfe: state.system.lfeSpeakers.contains(s.id), meters: meters)
                                .tag(Selection.speaker(s.id))
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                Spacer()
            }
            Divider()
            EngineStatusBar(model: model, meters: meters)
        }
        .modifier(DeleteSourceConfirmation(model: model, source: $deleting, selection: $selection))
    }

    /// Column titles and the list's add button.
    @ViewBuilder
    private func listHeader(_ state: ShowState) -> some View {
        HStack(spacing: 6) {
            switch tab {
            case .cues:
                Text("").frame(width: 14)
                Text("Cue").frame(width: 44, alignment: .trailing)
                Text("Name")
                Spacer()
                Text("Fade")
                Button { if let id = model.addCue(for: selectedSnapshot(state) ?? state.show.snapshots.last) { selection = .cue(id) } } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a cue at the end for the selected (or last) snapshot")
            case .snapshots:
                Text("Snapshot")
                Spacer()
                Button { if let id = model.storeSnapshot() { selection = .snapshot(id) } } label: {
                    Label("Store", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Store every source as a new snapshot")
            case .sources:
                Text("Source")
                Spacer()
                Text("Input level")
                Button { if let id = model.addSource() { selection = .source(id) } } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("Add a source on the next free Feral input (⇧⌘N)")
                Button {
                    var members: [UUID] = []
                    if case .source(let id) = selection { members = [id] }
                    if let id = model.addSourceGroup(with: members) { selection = .sourceGroup(id) }
                } label: {
                    Label("Group", systemImage: "square.stack.3d.up")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .help("Make a source group (with the selected source in it), then tick its members in the inspector (⇧⌘G)")
            case .speakers:
                Text("Speaker")
                Spacer()
                Text("Output level")
            }
        }
        .font(.caption.bold())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    /// A source's right-click menu.
    @ViewBuilder
    private func sourceMenu(_ s: Source, _ state: ShowState) -> some View {
        Button("Duplicate") { if let id = model.addSource(like: s) { selection = .source(id) } }
        Menu("Groups") {
            ForEach(state.show.sourceGroups) { g in
                let member = g.sources.contains(s.id)
                Button { model.setMember(s.id, of: g, !member) } label: {
                    if member { Label(g.label, systemImage: "checkmark") } else { Text(g.label) }
                }
            }
            if !state.show.sourceGroups.isEmpty { Divider() }
            Button("New group with this source") { if let id = model.addSourceGroup(with: [s.id]) { selection = .sourceGroup(id) } }
        }
        Divider()
        Button("Delete…", role: .destructive) { deleting = s }
    }

    private func selectedSnapshot(_ state: ShowState) -> Snapshot? {
        if case .snapshot(let id) = selection { return state.snapshot(id) }
        if case .cue(let id) = selection, let snap = state.cue(id)?.snapshot { return state.snapshot(snap) }
        return nil
    }
}

func groupOf(_ state: ShowState) -> [UUID: SpeakerGroup] {
    var map: [UUID: SpeakerGroup] = [:]
    for g in state.show.groups { for s in g.speakers where map[s] == nil { map[s] = g } }
    return map
}

/// The big GO button with the cue playing now and the next one.
struct GoPanel: View {
    @ObservedObject var model: EngineModel

    var body: some View {
        let state = model.state
        let current = model.status?.currentCue.flatMap { state?.cue($0) }
        let next = model.status?.nextCue.flatMap { state?.cue($0) }
        let fading = model.status?.fading.count ?? 0
        VStack(alignment: .leading, spacing: 8) {
            cueLine("NOW", current, color: .green)
            cueLine("NEXT", next, color: .accentColor)
            HStack(spacing: 8) {
                Button { model.go() } label: {
                    Text("GO").font(.title.bold()).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(next == nil)
                .help("Run the next cue (⌘↩)")
                Button { model.send(.stopFades) } label: {
                    Label("Stop", systemImage: "stop.fill").frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop every running fade where it is (⌘.)")
            }
            HStack(spacing: 6) {
                if fading > 0 {
                    ProgressView().controlSize(.mini)
                    Text("Fading \(fading) source(s)")
                } else {
                    Text("No fades running")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func cueLine(_ title: String, _ cue: Cue?, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.caption2.bold()).foregroundStyle(color).frame(width: 34, alignment: .leading)
            Text(cue?.number ?? "–").font(.title3.monospacedDigit().bold()).frame(minWidth: 36, alignment: .leading)
            Text(cue?.name ?? (cue == nil ? "none" : "")).font(.title3).lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

struct CueRow: View {
    let cue: Cue
    let state: ShowState
    let status: EngineStatus?

    var body: some View {
        let isCurrent = status?.currentCue == cue.id
        let isNext = status?.nextCue == cue.id
        let snapshot = cue.snapshot.flatMap { state.snapshot($0) }
        HStack(spacing: 6) {
            Image(systemName: isCurrent ? "play.fill" : "arrow.right")
                .foregroundStyle(isCurrent ? Color.green : Color.accentColor)
                .font(.caption)
                .opacity(isCurrent || isNext ? 1 : 0)
                .frame(width: 14)
            Text(cue.number).font(.body.monospacedDigit().bold()).frame(width: 44, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(cue.name ?? snapshot?.name ?? "Cue \(cue.number)").fontWeight(isCurrent ? .semibold : .regular).lineLimit(1)
                Text(snapshot.map { "snapshot \($0.label)" } ?? "marker (no snapshot)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if cue.reclaim { Image(systemName: "arrow.uturn.backward").font(.caption).help("Takes sources back from QLab or tracking") }
            if let f = cue.fadeSeconds ?? snapshot?.fadeSeconds {
                Text(f > 0 ? "\(f.short) s" : "cut").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if cue.autoFollow { Image(systemName: "arrow.turn.down.right").font(.caption).help("Auto-follow") }
        }
        .padding(.vertical, 2)
        .listRowBackground(isCurrent ? Color.green.opacity(0.18) : nil)
    }
}

struct SnapshotRow: View {
    let snapshot: Snapshot
    let recall: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("\(snapshot.number)").font(.body.monospacedDigit().bold()).frame(width: 30, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.name).lineLimit(1)
                Text("\(snapshot.sources.count) source(s) · \(snapshot.fadeSeconds.short) s \(curveName(snapshot.curve).lowercased())")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Recall", action: recall).buttonStyle(.borderless).font(.caption)
        }
        .padding(.vertical, 2)
    }
}

struct SourceRow: View {
    let source: Source
    let owner: PositionOwner
    @ObservedObject var meters: MeterStore

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(source.mute ? Color.clear : source.color)
                Circle().stroke(source.color, lineWidth: 1.5)
                Text("\(source.number)").font(.system(size: 9, weight: .bold)).foregroundStyle(source.mute ? source.color : Color.white)
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name ?? "Source \(source.number)").lineLimit(1)
                HStack(spacing: 4) {
                    Text("in \(source.input)")
                    if source.mute { Text("· muted") }
                    if owner != .cues { Text("· \(owner == .osc ? "OSC" : owner.label)").foregroundStyle(.orange) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            MeterBar(channel: meters.input(source.input), vertical: false, clear: { meters.clearClip(input: source.input) }).frame(width: 70, height: 7)
        }
        .padding(.vertical, 1)
    }
}

struct SourceGroupRow: View {
    let group: SourceGroup
    let state: ShowState

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4).fill(group.mute ? Color.clear : group.color)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(group.color, lineWidth: 1.5))
                .overlay(Text("\(group.number)").font(.system(size: 9, weight: .bold)).foregroundStyle(group.mute ? group.color : Color.white))
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(String(format: "%+.1f dB", group.gainDB)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    private var detail: String {
        let n = group.sources.filter { state.source($0) != nil }.count
        var parts = ["\(n) source\(n == 1 ? "" : "s")"]
        if group.mute { parts.append("muted") }
        if group.linked { parts.append("move together") }
        return parts.joined(separator: " · ")
    }
}

struct SpeakerRow: View {
    let speaker: Speaker
    let group: SpeakerGroup?
    let lfe: Bool
    @ObservedObject var meters: MeterStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "diamond.fill").foregroundStyle(group?.color ?? .gray).font(.caption).opacity(speaker.mute ? 0.3 : 1)
            Text("\(speaker.number)").font(.body.monospacedDigit().bold()).frame(width: 26, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(speaker.name ?? "Speaker \(speaker.number)").lineLimit(1)
                Text("out \(speaker.output)" + (group.map { " · \($0.name)" } ?? "") + (lfe ? " · LFE" : "")
                     + (speaker.mute ? " · muted" : ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            MeterBar(channel: meters.output(speaker.output), vertical: false, clear: { meters.clearClip(output: speaker.output) }).frame(width: 70, height: 7)
        }
        .padding(.vertical, 1)
    }
}

/// The engine's audio, OSC and MIDI at a glance, at the bottom of the sidebar.
struct EngineStatusBar: View {
    @ObservedObject var model: EngineModel
    @ObservedObject var meters: MeterStore

    var body: some View {
        let s = model.status
        VStack(alignment: .leading, spacing: 3) {
            EngineServiceRow(service: model.service, local: EngineService.isLocal(model.host))
            row(model.connected ? (s?.audio.hasPrefix("running") == true ? Color.green : Color.orange) : Color.red,
                "Audio", model.connected ? (s?.audio ?? "…") : "engine not connected (\(model.address))")
            row(s?.oscPort != nil ? Color.green : Color.secondary, "OSC", s.map { $0.osc.isEmpty ? "off" : $0.osc } ?? "–")
            row(s?.midi.isEmpty == false && s?.midi != "off" ? Color.green : Color.secondary, "MIDI", s.map { $0.midi.isEmpty ? "off" : $0.midi } ?? "–")
            if meters.live {
                row(meters.load > 0.8 ? Color.red : (meters.load > 0.5 ? Color.orange : Color.green), "Load",
                    String(format: "%.0f %% of a buffer at most", meters.load * 100))
            }
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ color: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).bold().frame(width: 38, alignment: .leading)
            Text(text).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(text)
        }
    }
}
#endif

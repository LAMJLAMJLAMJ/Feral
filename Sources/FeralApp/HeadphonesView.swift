#if canImport(SwiftUI) && os(macOS)
import AppKit
import FeralControl
import FeralScene
import SwiftUI

extension EngineModel {
    var soloed: Set<UUID> { Set(status?.solo ?? []) }
    var onPFL: Set<UUID> { Set(status?.pfl ?? []) }
    /// Something is soloed or on PFL, so the headphones are not hearing the whole mix.
    var isListening: Bool { !(status?.solo.isEmpty ?? true) || !(status?.pfl.isEmpty ?? true) }

    /// Puts sources (and the other side of a stereo pair) in or out of the solo, or of PFL. Option
    /// (exclusive) leaves only these.
    func toggleListen(_ ids: [UUID], pfl: Bool, exclusive: Bool = false) {
        let all = withStereoPartners(ids)
        var set = pfl ? onPFL : soloed
        let on = !all.allSatisfy { set.contains($0) }
        if exclusive { set = [] }
        if on { set.formUnion(all) } else { set.subtract(all) }
        let order = state?.show.sources.map(\.id) ?? []
        let list = order.filter { set.contains($0) }
        send(.listen(solo: pfl ? Array(status?.solo ?? []) : list, pfl: pfl ? list : Array(status?.pfl ?? [])))
    }

    func clearListen() { send(.listen(solo: [], pfl: [])) }

    func setMonitor(_ monitor: MonitorSettings?) { send(.setMonitor(monitor: monitor)) }
}

/// A strip's or the inspector's solo and PFL buttons. Option-click hears this one alone.
struct ListenButtons: View {
    @ObservedObject var model: EngineModel
    let source: UUID
    /// A mixer strip's narrow buttons.
    var compact = false

    var body: some View {
        let solo = model.soloed.contains(source), pfl = model.onPFL.contains(source)
        HStack(spacing: 2) {
            button("S", width: compact ? 22 : 44, on: solo, color: .yellow, help: solo ? "Take out of the headphones' solo" : "Solo in the headphones (Option: this alone)") {
                model.toggleListen([source], pfl: false, exclusive: NSEvent.modifierFlags.contains(.option))
            }
            button("PFL", width: compact ? 34 : 44, on: pfl, color: .green, help: pfl ? "Take off PFL" : "PFL: hear this input in the headphones in stereo (Option: this alone)") {
                model.toggleListen([source], pfl: true, exclusive: NSEvent.modifierFlags.contains(.option))
            }
        }
        .disabled(model.status?.monitor?.isOn != true)
    }

    private func button(_ text: String, width: CGFloat, on: Bool, color: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 10, weight: .bold))
                .frame(width: width, height: 18)
                .foregroundStyle(on ? Color.black : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? color : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The toolbar's headphones: the binaural monitor's settings, and what it hears.
struct HeadphonesButton: View {
    @ObservedObject var model: EngineModel
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Label("Headphones", systemImage: model.isListening ? "headphones.circle.fill" : "headphones")
        }
        .foregroundStyle(model.isListening ? Color.yellow : Color.primary)
        .help("The binaural headphone monitor: where it plays, and what it hears (the mix, a solo or PFL)")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            HeadphonesPanel(model: model).frame(width: 380)
        }
        .disabled(model.state == nil)
    }
}

struct HeadphonesPanel: View {
    @ObservedObject var model: EngineModel
    @State private var path = ""

    private var monitor: MonitorSettings? { model.status?.monitor }

    var body: some View {
        let m = monitor ?? MonitorSettings()
        Form {
            Section {
                Toggle("Binaural monitor", isOn: Binding(get: { m.isOn }, set: { on in
                    if on {
                        var n = m
                        let (l, r) = freePair()
                        guard let l, let r else {
                            model.lastError = "Every Feral output has a speaker. Add two outputs for the headphones first "
                                + "(Audio > Patch, Outputs: the count at the top right)."
                            return
                        }
                        n.left = l; n.right = r
                        model.setMonitor(n)
                    } else {
                        var n = m
                        n.left = nil; n.right = nil
                        model.setMonitor(n)
                    }
                }))
                if m.isOn {
                    outputRow("Left ear", value: m.left) { v in var n = m; n.left = v; model.setMonitor(n) }
                    outputRow("Right ear", value: m.right) { v in var n = m; n.right = v; model.setMonitor(n) }
                    LabeledContent("Level") {
                        LevelSlider(value: m.gainDB, range: -40...20, step: 0.5, unit: "dB") { v in var n = m; n.gainDB = v; model.setMonitor(n) }
                    }
                }
            } footer: {
                Text("Every speaker as heard from the listening point, for headphones: each one delayed and turned down for its distance "
                     + "and played through the ear responses for its direction. About 1.3 ms behind the speakers. "
                     + "Pick two Feral outputs no speaker uses, and patch them to your headphone outputs.")
            }
            if m.isOn {
                Section("Ear responses (HRTF)") {
                    Picker("Model", selection: Binding(get: { m.hrtf == nil }, set: { builtIn in
                        var n = m
                        n.hrtf = builtIn ? nil : (path.isEmpty ? nil : path)
                        if builtIn || !path.isEmpty { model.setMonitor(n) } else { choose(m) }
                    })) {
                        Text("Built-in head model").tag(true)
                        Text("Measured (KEMAR folder)").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    if m.hrtf != nil || !path.isEmpty {
                        HStack {
                            TextField("Folder", text: $path).onSubmit { var n = m; n.hrtf = path.isEmpty ? nil : path; model.setMonitor(n) }
                            Button("Choose…") { choose(m) }
                        }
                    }
                    Text("The head model gets left and right right but not above and below. The MIT KEMAR \"compact\" set "
                         + "(a folder of elev0, elev10 … with files like H0e090a.wav) is better.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Hearing") {
                    HStack {
                        Text(hearing).foregroundStyle(model.isListening ? Color.yellow : Color.primary)
                        Spacer()
                        Button("Clear") { model.clearListen() }.disabled(!model.isListening)
                    }
                    if let info = model.status?.monitorInfo, !info.isEmpty {
                        Text(info).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            path = monitor?.hrtf ?? ""
            model.refreshPatch()
        }
    }

    private var hearing: String {
        let pfl = model.status?.pfl.count ?? 0, solo = model.status?.solo.count ?? 0
        if pfl > 0 { return "PFL: \(pfl) source\(pfl == 1 ? "" : "s") in stereo" + (solo > 0 ? " (solo waits)" : "") }
        if solo > 0 { return "Solo: \(solo) source\(solo == 1 ? "" : "s"), binaural" }
        return "The whole mix, binaural"
    }

    private var speakerOutputs: Set<Int> { Set(model.state?.system.speakers.map(\.output) ?? []) }

    /// The two highest outputs no speaker uses.
    private func freePair() -> (Int?, Int?) {
        let count = model.patch?.outputs.count ?? 128
        let free = (1...max(count, 2)).reversed().filter { !speakerOutputs.contains($0) }
        guard free.count >= 2 else { return (nil, nil) }
        return (free[1], free[0])
    }

    private func outputRow(_ title: String, value: Int?, set: @escaping (Int?) -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                Stepper(value: Binding(get: { value ?? 1 }, set: { set($0) }), in: 1...256) {
                    Text(value.map { "output \($0)" } ?? "none").monospacedDigit()
                }
                if let v = value, speakerOutputs.contains(v) {
                    Text("a speaker's").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func choose(_ m: MonitorSettings) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the KEMAR compact folder (the one holding elev0, elev10 …)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path
        var n = m
        n.hrtf = url.path
        model.setMonitor(n)
    }
}
#endif

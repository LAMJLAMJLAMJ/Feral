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

/// The Binaural group's row in the Speakers list, above the output groups.
struct BinauralGroupRow: View {
    @ObservedObject var model: EngineModel

    var body: some View {
        let m = model.status?.monitor
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4).fill(Color.gray)
                .overlay(Image(systemName: "headphones").font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("Binaural").lineLimit(1)
                Text(detail(m)).font(.caption).foregroundStyle(m?.isOn == true ? Color.secondary : Color.orange).lineLimit(1)
            }
            Spacer(minLength: 4)
            if model.isListening { Text("SOLO").font(.caption2.bold()).foregroundStyle(.yellow) }
            Text(String(format: "%+.1f dB", m?.gainDB ?? 0)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
        .help("The headphone monitor: every speaker binaurally. Always here; it plays once Binaural L or R is patched.")
    }

    private func detail(_ m: MonitorSettings?) -> String {
        guard let m, m.isOn else { return "Headphones · not patched" }
        let sides = [m.left.map { "L → \($0)" }, m.right.map { "R → \($0)" }].compactMap { $0 }.joined(separator: ", ")
        return "Headphones · " + sides + (m.hrtf == nil ? " · head model" : " · KEMAR")
    }
}

/// The Binaural output group: always there, never deleted. Its two outputs (Binaural L and R) are
/// patched to card outputs in the Patch window; here are its level and ear responses, and what it hears.
struct HeadphonesPanel: View {
    @ObservedObject var model: EngineModel
    @Environment(\.openWindow) private var openWindow
    @State private var path = ""

    private var monitor: MonitorSettings? { model.status?.monitor }

    var body: some View {
        let m = monitor ?? MonitorSettings()
        Form {
            Section {
                LabeledContent("Binaural L") { Text(m.left.map { "card output \($0)" } ?? "not patched").monospacedDigit() }
                LabeledContent("Binaural R") { Text(m.right.map { "card output \($0)" } ?? "not patched").monospacedDigit() }
                Button("Patch…") { openWindow(id: "patch") }
                    .help("Binaural L and R are the last two rows of the Patch window's Outputs tab")
                if model.patch?.monitor == nil && model.patch != nil {
                    Label("Feral has too many outputs to leave room for Binaural L and R (at most 254).", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.caption)
                }
                LabeledContent("Level") {
                    LevelSlider(value: m.gainDB, range: -40...20, step: 0.5, unit: "dB") { v in var n = m; n.gainDB = v; model.setMonitor(n) }
                }
            } header: {
                HStack(spacing: 8) {
                    Image(systemName: "headphones")
                    Text("Binaural").font(.headline)
                }
            } footer: {
                Text("Every speaker as heard from the listening point, for headphones: each one delayed and turned down for its distance "
                     + "and played through the ear responses for its direction, about 1.3 ms behind the speakers. "
                     + "It plays once Binaural L or R is patched to a card output (Patch window, Outputs, the last two rows).")
            }
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

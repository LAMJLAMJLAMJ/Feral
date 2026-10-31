#if canImport(SwiftUI) && os(macOS)
import FeralControl
import FeralScene
import SwiftUI

/// Edits whatever is selected. Every edit is a request to the engine; the fields show the engine's
/// values, so a refused edit springs back.
struct InspectorView: View {
    @ObservedObject var model: EngineModel
    let state: ShowState
    @Binding var selection: Selection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch selection {
                case .source(let id):
                    if let s = state.source(id) { SourceInspector(model: model, state: state, source: s) }
                case .speaker(let id):
                    if let s = state.speaker(id) { SpeakerInspector(model: model, speaker: s) }
                case .snapshot(let id):
                    if let s = state.snapshot(id) { SnapshotInspector(model: model, state: state, snapshot: s, selection: $selection) }
                case .cue(let id):
                    if let c = state.cue(id) { CueInspector(model: model, state: state, cue: c, selection: $selection) }
                case nil:
                    Text("Select a source, speaker, snapshot or cue.")
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A number field that sends its value when edited.
struct NumberField: View {
    let title: String
    let value: Double
    let set: (Double) -> Void

    var body: some View {
        TextField(title, value: Binding(get: { value }, set: { set($0) }),
                  format: .number.precision(.fractionLength(0...3)))
    }
}

struct SourceInspector: View {
    @ObservedObject var model: EngineModel
    let state: ShowState
    let source: Source
    @State private var name = ""

    var body: some View {
        Form {
            Section("Source \(source.number) · input \(source.input)") {
                TextField("Name", text: $name)
                    .onSubmit {
                        var s = source
                        s.name = name.isEmpty ? nil : name
                        model.apply(.setSource(source: s))
                    }
                NumberField(title: "x (m)", value: source.position.x) { v in move(x: v) }
                NumberField(title: "y (m)", value: source.position.y) { v in move(y: v) }
                NumberField(title: "z (m)", value: source.position.z) { v in move(z: v) }
                let owner = model.status?.owner(of: source.id) ?? .cues
                LabeledContent("Position from") {
                    HStack {
                        Text(owner == .cues ? "cues" : "\(owner.label), live").foregroundStyle(owner == .cues ? Color.secondary : Color.orange)
                        if owner != .cues {
                            Button("Hand back to cues") { model.send(.release(sources: [source.id])) }
                        }
                    }
                }
            }
            Section("Level") {
                LabeledContent("Gain") {
                    HStack {
                        Slider(value: Binding(get: { source.gainDB }, set: { model.update(source.id, SourceValues(gainDB: ($0 * 2).rounded() / 2)) }),
                               in: -40...10)
                        Text("\(source.gainDB.short) dB").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                Toggle("Mute", isOn: Binding(get: { source.mute }, set: { model.update(source.id, SourceValues(mute: $0)) }))
                LabeledContent("Width (VBAP)") {
                    HStack {
                        Slider(value: Binding(get: { source.width }, set: { model.update(source.id, SourceValues(width: $0.rounded())) }),
                               in: 0...180)
                        Text("\(Int(source.width))°").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
            }
            Section("Sends") {
                ForEach(state.show.groups) { g in
                    SendRow(group: g, send: source.sends.first { $0.group == g.id }) { newSend in
                        var sends = source.sends.filter { $0.group != g.id }
                        if let newSend { sends.append(newSend) }
                        // Keep the groups' order.
                        sends.sort { a, b in
                            (state.show.groups.firstIndex { $0.id == a.group } ?? 0) < (state.show.groups.firstIndex { $0.id == b.group } ?? 0)
                        }
                        model.update(source.id, SourceValues(sends: sends))
                    }
                }
                if !state.system.lfeSpeakers.isEmpty {
                    Toggle("LFE send", isOn: Binding(get: { source.lfeDB != nil },
                                                     set: { model.update(source.id, $0 ? SourceValues(lfeDB: -10) : SourceValues(lfeOff: true)) }))
                    if let lfe = source.lfeDB {
                        LabeledContent("LFE") {
                            HStack {
                                Slider(value: Binding(get: { lfe }, set: { model.update(source.id, SourceValues(lfeDB: $0.rounded())) }), in: -40...10)
                                Text("\(lfe.short) dB").monospacedDigit().frame(width: 52, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { name = source.name ?? "" }
        .onChange(of: source.id) { _ in name = source.name ?? "" }
        .onChange(of: source.name) { n in name = n ?? "" }
    }

    private func move(x: Double? = nil, y: Double? = nil, z: Double? = nil) {
        let p = source.position
        model.update(source.id, SourceValues(position: Position(x ?? p.x, y ?? p.y, z ?? p.z)))
    }
}

struct SendRow: View {
    let group: SpeakerGroup
    let send: GroupSend?
    let change: (GroupSend?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("\(group.name) (\(group.renderer.rawValue))", isOn: Binding(
                get: { send != nil }, set: { change($0 ? GroupSend(group: group.id) : nil) }))
            if let send {
                HStack {
                    Slider(value: Binding(get: { send.gainDB },
                                          set: { change(GroupSend(group: group.id, gainDB: ($0 * 2).rounded() / 2)) }), in: -40...10)
                    Text("\(send.gainDB.short) dB").monospacedDigit().frame(width: 52, alignment: .trailing)
                }
            }
        }
    }
}

/// A speaker's position and system layer. EQ and the limiter are edited in system.json for now.
struct SpeakerInspector: View {
    @ObservedObject var model: EngineModel
    let speaker: Speaker
    @State private var name = ""

    var body: some View {
        Form {
            Section("Speaker \(speaker.number) · output \(speaker.output)") {
                TextField("Name", text: $name).onSubmit { set { $0.name = name.isEmpty ? nil : name } }
                NumberField(title: "x (m)", value: speaker.position.x) { v in set { $0.position.x = v } }
                NumberField(title: "y (m)", value: speaker.position.y) { v in set { $0.position.y = v } }
                NumberField(title: "z (m)", value: speaker.position.z) { v in set { $0.position.z = v } }
            }
            Section("System layer (cues never change it)") {
                NumberField(title: "Delay (ms)", value: speaker.delayMS) { v in set { $0.delayMS = max(0, min(v, 1000)) } }
                NumberField(title: "Trim (dB)", value: speaker.trimDB) { v in set { $0.trimDB = min(v, 24) } }
                Toggle("Polarity inverted", isOn: Binding(get: { speaker.invert }, set: { v in set { $0.invert = v } }))
                Toggle("Mute", isOn: Binding(get: { speaker.mute }, set: { v in set { $0.mute = v } }))
                LabeledContent("EQ bands", value: "\(speaker.eq.count)")
                LabeledContent("Limiter", value: speaker.limiterDB.map { "\($0.short) dBFS" } ?? "off")
            }
        }
        .formStyle(.grouped)
        .onAppear { name = speaker.name ?? "" }
        .onChange(of: speaker.id) { _ in name = speaker.name ?? "" }
    }

    private func set(_ change: (inout Speaker) -> Void) {
        var s = speaker
        change(&s)
        model.apply(.setSpeaker(speaker: s))
    }
}

struct SnapshotInspector: View {
    @ObservedObject var model: EngineModel
    let state: ShowState
    let snapshot: Snapshot
    @Binding var selection: Selection?
    @State private var name = ""
    @State private var recallFade: Double?

    var body: some View {
        Form {
            Section("Snapshot \(snapshot.number)") {
                TextField("Name", text: $name).onSubmit { set { $0.name = name.isEmpty ? "Snapshot \(snapshot.number)" : name } }
                NumberField(title: "Fade (s)", value: snapshot.fadeSeconds) { v in set { $0.fadeSeconds = max(0, min(v, 3600)) } }
                Picker("Curve", selection: Binding(get: { snapshot.curve }, set: { v in set { $0.curve = v } })) {
                    ForEach(FadeCurve.allCases, id: \.self) { Text(curveName($0)).tag($0) }
                }
                LabeledContent("Stores", value: "\(snapshot.sources.count) source(s)")
            }
            Section {
                Button("Recall over \(snapshot.fadeSeconds.short) s") { model.recall(snapshot) }
                Button("Recall now") { model.recall(snapshot, fadeSeconds: 0) }
                Button("Update from the sources as they are") { model.restore(snapshot) }
                Button("Add a cue for it") { if let id = model.addCue(for: snapshot) { selection = .cue(id) } }
                Button("Delete", role: .destructive) {
                    model.apply(.removeSnapshot(id: snapshot.id))
                    selection = nil
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { name = snapshot.name }
        .onChange(of: snapshot.id) { _ in name = snapshot.name }
    }

    private func set(_ change: (inout Snapshot) -> Void) {
        var s = snapshot
        change(&s)
        model.apply(.setSnapshot(snapshot: s))
    }
}

struct CueInspector: View {
    @ObservedObject var model: EngineModel
    let state: ShowState
    let cue: Cue
    @Binding var selection: Selection?
    @State private var number = ""
    @State private var name = ""

    var body: some View {
        Form {
            Section("Cue \(cue.number)") {
                TextField("Number", text: $number).onSubmit { if Double(number) != nil { set { $0.number = number } } }
                TextField("Name", text: $name).onSubmit { set { $0.name = name.isEmpty ? nil : name } }
                Picker("Snapshot", selection: Binding(get: { cue.snapshot }, set: { v in set { $0.snapshot = v } })) {
                    Text("None (a marker)").tag(UUID?.none)
                    ForEach(state.show.snapshots.sorted { $0.number < $1.number }) { s in Text(s.label).tag(UUID?.some(s.id)) }
                }
                Toggle("Own fade time", isOn: Binding(get: { cue.fadeSeconds != nil },
                                                      set: { on in set { $0.fadeSeconds = on ? fallbackFade : nil } }))
                if let f = cue.fadeSeconds {
                    NumberField(title: "Fade (s)", value: f) { v in set { $0.fadeSeconds = max(0, min(v, 3600)) } }
                }
                Picker("Curve", selection: Binding(get: { cue.curve }, set: { v in set { $0.curve = v } })) {
                    Text("The snapshot's").tag(FadeCurve?.none)
                    ForEach(FadeCurve.allCases, id: \.self) { Text(curveName($0)).tag(FadeCurve?.some($0)) }
                }
                Toggle("Auto-follow (go on to the next cue when the fade ends)",
                       isOn: Binding(get: { cue.autoFollow }, set: { v in set { $0.autoFollow = v } }))
                Toggle("Take sources back from QLab or tracking",
                       isOn: Binding(get: { cue.reclaim }, set: { v in set { $0.reclaim = v } }))
            }
            Section {
                Button("GO this cue") { model.go(cue.id.uuidString) }
                Button("Delete", role: .destructive) {
                    model.apply(.removeCue(id: cue.id))
                    selection = nil
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { number = cue.number; name = cue.name ?? "" }
        .onChange(of: cue.id) { _ in number = cue.number; name = cue.name ?? "" }
    }

    private var fallbackFade: Double { cue.snapshot.flatMap { state.snapshot($0) }?.fadeSeconds ?? 0 }

    private func set(_ change: (inout Cue) -> Void) {
        var c = cue
        change(&c)
        model.apply(.setCue(cue: c))
    }
}

func curveName(_ c: FadeCurve) -> String {
    switch c {
    case .linear: return "Linear"
    case .sCurve: return "S-curve"
    case .exponential: return "Exponential (slow start)"
    }
}
#endif

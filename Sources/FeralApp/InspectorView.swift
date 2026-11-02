#if canImport(SwiftUI) && os(macOS)
import FeralControl
import FeralScene
import SwiftUI

/// Edits whatever is selected. Every edit is a request to the engine; the fields show the engine's
/// values, so a refused edit springs back.
struct InspectorView: View {
    @ObservedObject var model: EngineModel
    let meters: MeterStore
    let state: ShowState
    @Binding var selection: Selection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch selection {
                case .source(let id):
                    if let s = state.source(id) { SourceInspector(model: model, meters: meters, state: state, source: s, selection: $selection) }
                case .speaker(let id):
                    if let s = state.speaker(id) { SpeakerInspector(model: model, meters: meters, state: state, speaker: s) }
                case .snapshot(let id):
                    if let s = state.snapshot(id) { SnapshotInspector(model: model, state: state, snapshot: s, selection: $selection) }
                case .cue(let id):
                    if let c = state.cue(id) { CueInspector(model: model, state: state, cue: c, selection: $selection) }
                case nil:
                    ShowSummary(state: state)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// What the inspector shows with nothing selected.
struct ShowSummary: View {
    let state: ShowState

    var body: some View {
        Form {
            Section(state.show.name) {
                LabeledContent("Sources", value: "\(state.show.sources.count)")
                LabeledContent("Speakers", value: "\(state.system.speakers.count)")
                LabeledContent("Groups", value: state.show.groups.map(\.name).joined(separator: ", ").isEmpty ? "none"
                               : state.show.groups.map(\.name).joined(separator: ", "))
                LabeledContent("Snapshots", value: "\(state.show.snapshots.count)")
                LabeledContent("Cues", value: "\(state.show.cues.count)")
                LabeledContent("OSC and MIDI triggers", value: "\(state.show.control.triggers.count)")
            }
            Section {
                Text("Select a cue, snapshot, source or speaker in the list, on the plan or on the meter bridge to edit it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// A live meter that redraws on its own, so the form around it does not redraw 20 times a second.
struct LiveMeter: View {
    @ObservedObject var meters: MeterStore
    let input: Int?
    let output: Int?

    var body: some View {
        if let input {
            MeterReadout(title: inputTitle(input), channel: meters.input(input), clear: { meters.clearClip(input: input) })
        } else if let output {
            MeterReadout(title: outputTitle(output), channel: meters.output(output), clear: { meters.clearClip(output: output) })
        }
    }

    private func inputTitle(_ n: Int) -> String {
        let card = meters.cardInput(n)
        return "Input \(n) · " + (card > 0 ? "card input \(card)" : "not patched")
    }

    private func outputTitle(_ n: Int) -> String {
        let card = meters.cardOutput(n)
        return "Output \(n) · " + (card > 0 ? "card output \(card)" : "not patched")
    }
}

/// A slider for a value the engine owns. While it is dragged it follows the mouse from its own copy
/// of the value (sending changes to the engine up to 30 times a second), instead of waiting for each
/// change to come back from the engine, which made it stick. When it is let go it sends the final
/// value and shows the engine's again.
struct LevelSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let set: (Double) -> Void
    @State private var dragged: Double?
    @State private var dragging = false
    @State private var lastSent = Date.distantPast

    var body: some View {
        let shown = dragged ?? value
        HStack {
            Slider(value: Binding(get: { shown }, set: { change($0) }), in: range, onEditingChanged: { active in
                dragging = active
                if !active {
                    if let d = dragged { set(d) }
                    dragged = nil
                }
            })
            Text(label(shown)).monospacedDigit().frame(width: 58, alignment: .trailing)
        }
    }

    private func change(_ raw: Double) {
        let v = min(max((raw / step).rounded() * step, range.lowerBound), range.upperBound)
        guard dragging else {
            // A click or a key: no drag to follow, send it now.
            set(v)
            return
        }
        dragged = v
        if Date().timeIntervalSince(lastSent) >= 1.0 / 30 {
            lastSent = Date()
            set(v)
        }
    }

    private func label(_ v: Double) -> String {
        unit == "°" ? "\(Int(v.rounded()))°" : String(format: step < 1 ? "%.1f %@" : "%.0f %@", v, unit)
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
    let meters: MeterStore
    let state: ShowState
    let source: Source
    @Binding var selection: Selection?
    @State private var name = ""
    @State private var input = 1
    @State private var deleting: Source?

    var body: some View {
        Form {
            Section {
                LiveMeter(meters: meters, input: source.input, output: nil)
                LabeledContent("Feral input") {
                    HStack(spacing: 6) {
                        TextField("Feral input", value: $input, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 56)
                            .onSubmit { model.setInput(input, of: source); input = source.input }
                        Stepper("Feral input", value: Binding(get: { source.input }, set: { model.setInput($0, of: source) }),
                                in: 1...max(model.feralInputs, 1))
                            .labelsHidden()
                    }
                }
                .help("The Feral input this source plays. Which card input feeds it is set in Audio > Patch.")
            } header: {
                HStack(spacing: 8) {
                    Circle().fill(source.color).frame(width: 12, height: 12)
                    Text("Source \(source.number)").font(.headline)
                    Text(source.name ?? "").foregroundStyle(.secondary)
                }
            }
            Section("Name and position") {
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
                    LevelSlider(value: source.gainDB, range: -40...10, step: 0.5, unit: "dB") {
                        model.update(source.id, SourceValues(gainDB: $0))
                    }
                }
                Toggle("Mute", isOn: Binding(get: { source.mute }, set: { model.update(source.id, SourceValues(mute: $0)) }))
                LabeledContent("Width (VBAP)") {
                    LevelSlider(value: source.width, range: 0...180, step: 1, unit: "°") {
                        model.update(source.id, SourceValues(width: $0))
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
                            LevelSlider(value: lfe, range: -40...10, step: 1, unit: "dB") {
                                model.update(source.id, SourceValues(lfeDB: $0))
                            }
                        }
                    }
                }
            }
        }
            Section {
                HStack {
                    Button("Duplicate") { if let id = model.addSource(like: source) { selection = .source(id) } }
                        .help("A new source on the next free Feral input, with the same sends and levels")
                    Spacer()
                    Button("Delete source…", role: .destructive) { deleting = source }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { name = source.name ?? ""; input = source.input }
        .onChange(of: source.id) { _ in name = source.name ?? ""; input = source.input }
        .onChange(of: source.name) { n in name = n ?? "" }
        .onChange(of: source.input) { n in input = n }
        .modifier(DeleteSourceConfirmation(model: model, source: $deleting, selection: $selection))
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
                LevelSlider(value: send.gainDB, range: -40...10, step: 0.5, unit: "dB") {
                    change(GroupSend(group: group.id, gainDB: $0))
                }
            }
        }
    }
}

/// A speaker's position and system layer. EQ and the limiter are edited in system.json for now.
struct SpeakerInspector: View {
    @ObservedObject var model: EngineModel
    let meters: MeterStore
    let state: ShowState
    let speaker: Speaker
    @State private var name = ""

    var body: some View {
        let groups = state.show.groups.filter { $0.speakers.contains(speaker.id) }
        Form {
            Section {
                LiveMeter(meters: meters, input: nil, output: speaker.output)
                LabeledContent("Groups", value: groups.isEmpty ? "none" : groups.map { "\($0.name) (\($0.renderer.rawValue))" }
                    .joined(separator: ", "))
                if state.system.lfeSpeakers.contains(speaker.id) { LabeledContent("LFE", value: "takes the sources' LFE sends") }
            } header: {
                HStack(spacing: 8) {
                    Image(systemName: "diamond.fill").foregroundStyle(groups.first?.color ?? .gray)
                    Text("Speaker \(speaker.number)").font(.headline)
                    Text(speaker.name ?? "").foregroundStyle(.secondary)
                }
            }
            Section("Name and position") {
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
/// Asks before deleting a source: cues and snapshots keep working, but the source is gone from the show.
struct DeleteSourceConfirmation: ViewModifier {
    @ObservedObject var model: EngineModel
    @Binding var source: Source?
    @Binding var selection: Selection?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete source \(source?.label ?? "")?",
            isPresented: Binding(get: { source != nil }, set: { if !$0 { source = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let s = source {
                    model.apply(.removeSource(id: s.id))
                    if selection == .source(s.id) { selection = nil }
                }
                source = nil
            }
            Button("Cancel", role: .cancel) { source = nil }
        } message: {
            Text("It stops playing at once. Snapshots that hold it skip it from then on.")
        }
    }
}
#endif

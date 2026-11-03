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
                case .listener:
                    ListenerInspector(model: model, state: state)
                case .binaural:
                    HeadphonesPanel(model: model)
                case .lfe:
                    LFEGroupInspector(model: model, state: state)
                case .speakerGroup(let id):
                    if let g = state.group(id) { OutputGroupInspector(model: model, state: state, group: g, selection: $selection) }
                case .sourceGroup(let id):
                    if let g = state.sourceGroup(id) {
                        if g.stereo, let left = state.stereoPair(g)?.left {
                            SourceInspector(model: model, meters: meters, state: state, source: left, selection: $selection)
                        } else {
                            SourceGroupInspector(model: model, state: state, group: g, selection: $selection)
                        }
                    }
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
            Section("Listener") {
                let l = state.system.listener
                LabeledContent("Position", value: String(format: "%.1f, %.1f, %.1f m", l.position.x, l.position.y, l.position.z))
                LabeledContent("Facing", value: String(format: "%.0f°", l.facing))
                Text("Click the listener on the plan to move or turn it.").font(.caption).foregroundStyle(.secondary)
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
    /// Shows the value; none gives "3.5 dB" or "45°".
    var format: ((Double) -> String)? = nil
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
        if let format { return format(v) }
        return unit == "°" ? "\(Int(v.rounded()))°" : String(format: step < 1 ? "%.1f %@" : "%.0f %@", v, unit)
    }
}

/// A number field that sends its value when edited.
/// A number the engine owns, typed as text and sent on Return or when the field loses focus, so a
/// half-typed value such as "-" or "-1." is not thrown away while typing.
struct NumberField: View {
    let title: String
    let value: Double
    let set: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .focused($focused)
            .onSubmit(commit)
            .onAppear { text = Self.format(value) }
            .onChange(of: focused) { _, now in if !now { commit() } }
            .onChange(of: value) { _, v in if !focused { text = Self.format(v) } }
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\u{2212}", with: "-")   // a typographic minus
            .replacingOccurrences(of: ",", with: ".")
        if let v = Double(t), v.isFinite {
            if v != value { set(v) }
            text = Self.format(v)
        } else {
            text = Self.format(value)
        }
    }

    static func format(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...3)).grouping(.never))
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
                LabeledContent("Headphones") { ListenButtons(model: model, source: source.id) }
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
                PolarControls(listener: state.system.listener, position: source.position) { p in
                    model.drag(source.id, from: source.position, to: p, partners: model.dragPartners(of: source.id))
                }
                Button("Snap to nearest speaker") { model.snapToNearestSpeakers([source.id]) }
                    .help("Moves the source onto the nearest speaker of the groups it sends to (a stereo pair: each side)")
                let groups = state.sourceGroups(of: source.id).filter { !$0.stereo }
                if !groups.isEmpty {
                    LabeledContent("Groups") {
                        Text(groups.map(\.label).joined(separator: ", ")).foregroundStyle(.secondary)
                    }
                }
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
                LabeledContent("Spread") {
                    LevelSlider(value: source.width, range: 0...360, step: 1, unit: "°") {
                        model.update(source.id, SourceValues(width: $0))
                    }
                }
                .help("Spreads the source across this many degrees around the listener, in every algorithm")
            }
            DistanceSection(model: model, state: state, source: source)
            if let pair = model.stereoPair(of: source.id) {
                StereoSection(model: model, state: state, group: pair.group, current: source.id, selection: $selection)
            }
            Section("Input") {
                LabeledContent("Trim") {
                    LevelSlider(value: source.trimDB, range: -24...24, step: 0.5, unit: "dB") {
                        model.update(source.id, SourceValues(trimDB: $0))
                    }
                }
                Toggle("Invert polarity", isOn: Binding(get: { source.invert }, set: { model.update(source.id, SourceValues(invert: $0)) }))
                LabeledContent("Delay") {
                    HStack {
                        LevelSlider(value: source.delayMS, range: 0...200, step: 0.1, unit: "ms") {
                            model.update(source.id, SourceValues(delayMS: $0))
                        }
                        NumberField(title: "ms", value: source.delayMS) { v in
                            model.update(source.id, SourceValues(delayMS: min(max(v, 0), 1000)))
                        }
                        .labelsHidden()
                        .frame(width: 60)
                    }
                }
                .help("Delays the source (0 to 1000 ms; the slider goes to 200, type more) so the PA lands just after its sound on stage")
            }
            Section {
                LiveEQControls(model: model, spectrum: model.spectrum, source: source)
            } header: {
                Text("EQ")
            } footer: {
                if state.stereoPartner(of: source.id) != nil {
                    Text("A stereo pair's level, mute, EQ and compressor are always the same on both sides.")
                }
            }
            Section("Compressor") {
                LiveCompressorControls(model: model, meters: meters, spectrum: model.spectrum, source: source)
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
            Toggle("\(group.name) (\(group.renderer.title))", isOn: Binding(
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
                if state.system.lfeSpeakers.contains(speaker.id) { LabeledContent("LFE", value: "takes the sources' LFE sends") }
            } header: {
                HStack(spacing: 8) {
                    Image(systemName: "diamond.fill").foregroundStyle(groups.first?.color ?? .gray)
                    Text("Speaker \(speaker.number)").font(.headline)
                    Text(speaker.name ?? "").foregroundStyle(.secondary)
                }
            }
            Section("Output groups") {
                if groups.isEmpty && !state.system.lfeSpeakers.contains(speaker.id) {
                    Label("In no output group, so it plays nothing. Tick one below.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                ForEach(state.show.groups) { g in
                    Toggle("\(g.name) (\(g.renderer.title))", isOn: Binding(get: { g.speakers.contains(speaker.id) },
                                                                          set: { model.setSpeakers([speaker.id], of: g, $0) }))
                }
                Toggle("LFE (\(state.system.lfeMode.title))", isOn: Binding(get: { state.system.lfeSpeakers.contains(speaker.id) }, set: { on in
                    var list = state.system.lfeSpeakers.filter { $0 != speaker.id }
                    if on { list.append(speaker.id) }
                    model.apply(.setLFESpeakers(speakers: list))
                }))
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
                LabeledContent("Sources", value: "\(snapshot.sources.count)")
            }
            Section {
                let stored = state.fields(of: snapshot)
                ForEach(SnapshotField.allCases, id: \.self) { f in
                    Toggle(fieldName(f), isOn: Binding(get: { stored.contains(f) },
                                                       set: { on in model.apply(.setSnapshot(snapshot: state.snapshot(snapshot, storing: f, on))) }))
                }
            } header: {
                Text("Stores")
            } footer: {
                Text("Turning a field on stores it from the sources as they are now. A recall only changes the fields it stores.")
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

/// A source's distance modelling: level falling with distance from the listener, and air absorption.
struct DistanceSection: View {
    @ObservedObject var model: EngineModel
    let state: ShowState
    let source: Source

    var body: some View {
        let d = source.distance ?? .off
        let metres = source.position.distance(to: state.system.listener.position)
        Section {
            Toggle("Distance modelling", isOn: Binding(get: { d.on }, set: { on in set { $0.on = on } }))
            if d.on {
                LabeledContent("Roll-off") {
                    LevelSlider(value: d.rolloffDB, range: 0...24, step: 0.5, unit: "dB",
                                format: { String(format: "%.1f dB per doubling", $0) }) { v in set { $0.rolloffDB = v } }
                }
                .help("How much quieter per doubling of distance from the listener; 6 dB is the inverse square law")
                LabeledContent("From") {
                    LevelSlider(value: d.referenceM, range: 0.5...50, step: 0.5, unit: "m") { v in set { $0.referenceM = v } }
                }
                .help("Within this distance of the listener the level is unchanged")
                LabeledContent("Air absorption") {
                    LevelSlider(value: d.air, range: 0...4, step: 0.1, unit: "",
                                format: { $0 == 0 ? "off" : String(format: "%.1f× real air", $0) }) { v in set { $0.air = v } }
                }
                .help("Takes off the highs (above about 7 kHz) as air would over the distance; 1 is real air, more exaggerates it")
                LabeledContent("Now", value: String(format: "%.1f m: %.1f dB, highs %.1f dB", metres, d.levelDB(at: metres), d.airDB(at: metres)))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Distance")
        } footer: {
            if d.on { Text("Measured from the listener. On top of the output groups' own roll-off.") }
        }
    }

    private func set(_ change: (inout SourceDistance) -> Void) {
        var d = source.distance ?? .off
        change(&d)
        model.update(source.id, SourceValues(distance: d))
    }
}

func fieldName(_ f: SnapshotField) -> String {
    switch f {
    case .position: return "Position"
    case .gain: return "Level"
    case .mute: return "Mute"
    case .width: return "Spread"
    case .sends: return "Sends"
    case .lfe: return "LFE send"
    case .input: return "Input (trim, polarity, delay)"
    case .eq: return "EQ"
    case .compressor: return "Compressor"
    case .distance: return "Distance modelling"
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
            source.flatMap { model.stereoPair(of: $0.id) }.map { "Delete stereo source \($0.group.name) (both sides)?" }
                ?? "Delete source \(source?.label ?? "")?",
            isPresented: Binding(get: { source != nil }, set: { if !$0 { source = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let s = source {
                    model.deleteSources([s.id])
                    selection = nil
                }
                source = nil
            }
            Button("Cancel", role: .cancel) { source = nil }
        } message: {
            Text("It stops playing at once. Snapshots that hold it skip it from then on.")
        }
    }
}
/// Azimuth, elevation and distance from the venue's origin, as sliders. Azimuth 0 is straight ahead
/// (towards +y), positive to the left; elevation 90 is straight up.
struct PolarControls: View {
    let listener: Listener
    let position: Position
    let set: (Position) -> Void

    var body: some View {
        let p = listener.polar(of: position)
        LabeledContent("Azimuth") {
            LevelSlider(value: p.azimuth, range: -180...180, step: 1, unit: "°") { a in
                set(listener.point(Polar(azimuth: a, elevation: p.elevation, distance: p.distance)))
            }
        }
        .help("Degrees from the way the listener faces, positive to the left (as ADM-OSC)")
        LabeledContent("Elevation") {
            LevelSlider(value: p.elevation, range: -90...90, step: 1, unit: "°") { e in
                set(listener.point(Polar(azimuth: p.azimuth, elevation: e, distance: p.distance)))
            }
        }
        .help("Degrees up from the listener's height")
        LabeledContent("Distance") {
            LevelSlider(value: p.distance, range: 0...max(50, (p.distance * 1.5).rounded()), step: 0.1, unit: "m") { d in
                set(listener.point(Polar(azimuth: p.azimuth, elevation: p.elevation, distance: d)))
            }
        }
        .help("Metres from the listener")
    }
}

/// The listening point: where it is among the speakers and which way it faces.
struct ListenerInspector: View {
    @ObservedObject var model: EngineModel
    let state: ShowState

    var body: some View {
        let l = state.system.listener
        Form {
            Section {
                NumberField(title: "x (m)", value: l.position.x) { v in set(Position(v, l.position.y, l.position.z), l.facing) }
                NumberField(title: "y (m)", value: l.position.y) { v in set(Position(l.position.x, v, l.position.z), l.facing) }
                NumberField(title: "z (m)", value: l.position.z) { v in set(Position(l.position.x, l.position.y, v), l.facing) }
                LabeledContent("Facing") {
                    LevelSlider(value: l.facing, range: -180...180, step: 1, unit: "°") { set(l.position, $0) }
                }
                .help("The way azimuth 0 points, in degrees from +y, positive to the left. 180 faces -y.")
                HStack {
                    Button("Face +y (0°)") { set(l.position, 0) }
                    Button("Face −y (180°)") { set(l.position, 180) }
                }
            } header: {
                Text("Listener").font(.headline)
            } footer: {
                Text("Sources' azimuth, elevation and distance are measured from here, in the speakers' coordinates. "
                     + "Speakers stay where they are. Turn on Move speakers to drag the listener on the plan.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func set(_ p: Position, _ facing: Double) {
        model.apply(.setListener(listener: Listener(position: p, facing: facing)))
    }
}


/// A source group: name, VCA-style gain and mute, moving together, its centre as azimuth, elevation
/// and distance, and which sources are in it.
struct SourceGroupInspector: View {
    @ObservedObject var model: EngineModel
    let state: ShowState
    let group: SourceGroup
    @Binding var selection: Selection?
    @State private var name = ""

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .onSubmit { var g = group; g.name = name.isEmpty ? "Group \(group.number)" : name; model.setSourceGroup(g) }
            } header: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(group.color).frame(width: 12, height: 12)
                    Text("Source group \(group.number)").font(.headline)
                }
            }
            Section("Level") {
                LabeledContent("Group gain") {
                    LevelSlider(value: group.gainDB, range: -40...10, step: 0.5, unit: "dB") { v in
                        var g = group; g.gainDB = v; model.setSourceGroup(g)
                    }
                }
                .help("Adds to every member's own gain, like a VCA")
                Toggle("Mute", isOn: Binding(get: { group.mute }, set: { var g = group; g.mute = $0; model.setSourceGroup(g) }))
            }
            if group.stereo { StereoSection(model: model, state: state, group: group, selection: $selection) }
            Section("Position") {
                if !group.stereo {
                    Toggle("Move together", isOn: Binding(get: { group.linked }, set: { var g = group; g.linked = $0; model.setSourceGroup(g) }))
                        .help("Dragging one member on the plan or the height view moves the others with it")
                }
                if let c = state.centre(of: group) {
                    GroupPolarControls(model: model, group: group, centre: c)
                    LabeledContent("Centre") {
                        Text(String(format: "x %.1f  y %.1f  z %.1f m", c.x, c.y, c.z)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Add sources to move the group.").foregroundStyle(.secondary)
                }
            }
            if !group.stereo {
            Section("Sources in the group") {
                if state.show.sources.isEmpty { Text("The show has no sources.").foregroundStyle(.secondary) }
                ForEach(state.show.sources) { s in
                    Toggle(isOn: Binding(get: { group.sources.contains(s.id) }, set: { model.setMember(s.id, of: group, $0) })) {
                        HStack(spacing: 6) {
                            Circle().fill(s.color).frame(width: 9, height: 9)
                            Text(s.name ?? "Source \(s.number)")
                            Text("\(s.number)").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            }
            Section {
                Button("Delete group", role: .destructive) {
                    model.apply(.removeSourceGroup(id: group.id))
                    selection = nil
                }
                .help("Deletes the group only; its sources stay")
            }
        }
        .formStyle(.grouped)
        .onAppear { name = group.name }
        .onChange(of: group.id) { _, _ in name = group.name }
        .onChange(of: group.name) { _, n in name = n }
    }
}

/// A group's centre as azimuth, elevation and distance: moving one turns, raises or spreads the
/// whole group, keeping its shape.
struct GroupPolarControls: View {
    @ObservedObject var model: EngineModel
    let group: SourceGroup
    let centre: Position

    var body: some View {
        let p = model.state?.polar(of: centre) ?? centre.polar
        LabeledContent("Azimuth") {
            LevelSlider(value: p.azimuth, range: -180...180, step: 1, unit: "°") { model.moveGroup(group, azimuth: $0) }
        }
        .help("Turns the whole group round the listener; 0 is the way the listener faces, positive to the left")
        LabeledContent("Elevation") {
            LevelSlider(value: p.elevation, range: -90...90, step: 1, unit: "°") { model.moveGroup(group, elevation: $0) }
        }
        .help("Raises or lowers every member by the same angle")
        LabeledContent("Distance") {
            LevelSlider(value: p.distance, range: 0...max(50, (p.distance * 1.5).rounded()), step: 0.1, unit: "m") {
                model.moveGroup(group, distance: $0)
            }
        }
        .help("Moves the whole group nearer or further, scaling each member's distance")
    }
}
/// A stereo pair's own controls: paired or not, the spacing between left and right, and the two sides.
struct StereoSection: View {
    @ObservedObject var model: EngineModel
    let state: ShowState
    let group: SourceGroup
    /// The side the inspector shows.
    var current: UUID? = nil
    @Binding var selection: Selection?
    @State private var name = ""

    var body: some View {
        Section {
            TextField("Pair name", text: $name)
                .onSubmit { var g = group; g.name = name.isEmpty ? "Stereo \(group.number)" : name; model.setSourceGroup(g) }
                .onAppear { name = group.name }
                .onChange(of: group.name) { _, n in name = n }
            Toggle("Paired", isOn: Binding(get: { group.linked }, set: { var g = group; g.linked = $0; model.setSourceGroup(g) }))
                .help("Paired: left and right move together. Unpair to place each side on its own; pair again and they move together from there.")
            if let spacing = state.spacing(of: group) {
                LabeledContent("Spacing") {
                    LevelSlider(value: max(spacing, 0), range: 0...180, step: 1, unit: "°") { model.setSpacing(group, $0) }
                }
                .help("The azimuth between left and right, seen from the listener; 0 puts them on top of each other")
            }
            if let pair = state.stereoPair(group) {
                // Which side the position fields below edit (level and processing are always both).
                Picker("Editing", selection: Binding(get: { current == pair.right.id ? 1 : 0 },
                                                     set: { selection = .source($0 == 1 ? pair.right.id : pair.left.id) })) {
                    Text("Left (in \(pair.left.input))").tag(0)
                    Text("Right (in \(pair.right.input))").tag(1)
                }
                .pickerStyle(.segmented)
            } else {
                Text("A stereo pair needs its left and right sources.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Stereo")
        } footer: {
            Text(group.linked ? "Level, trim, delay, EQ and compressor are always the same on both sides. The name, Feral input and position below are this side's."
                 : "Unpaired: drag or edit each side's position on its own. Pair again to move them together from where they are.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif

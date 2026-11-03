#if canImport(SwiftUI) && os(macOS)
import FeralScene
import SwiftUI

extension Renderer {
    var title: String {
        switch self {
        case .delay: return "Delay"
        case .vbap: return "VBAP"
        case .dbap: return "DBAP"
        case .knn: return "KNN"
        case .spcap: return "SPCAP"
        case .pan: return "Pan (stereo, LCR)"
        }
    }

    var explanation: String {
        switch self {
        case .delay: return "Level and delay per speaker from the source's distance, so the sound seems to come from the stage. The main one for reinforcement."
        case .vbap: return "Amplitude panning between the nearest two or three speakers, around the listening point. Sharp; for surrounds, rings and domes."
        case .dbap: return "Level from each speaker's distance to the source, with no sweet spot. For irregular layouts."
        case .knn: return "As few speakers as possible: only the K nearest play, fading out over the spread. On a speaker with spread 0, only that one plays."
        case .spcap: return "A cardioid over every speaker, turned down where speakers are crowded. Smooth, for irregular layouts; uses many speakers."
        case .pan: return "A console pan pot: the source's position across the stage, left to right as the listener faces, pans between the two neighbouring speakers with a pan law. For stereo, LCR and rows of speakers; past the ends a source stays in the end speaker."
        }
    }
}

extension LFEMode {
    var title: String {
        switch self {
        case .equal: return "Equal (every sub the same)"
        case .delay: return "Delay"
        case .dbap: return "DBAP"
        case .pan: return "Pan (stereo, LCR)"
        }
    }

    var explanation: String {
        switch self {
        case .equal: return "Every source's LFE send reaches every sub at the same level, with no delay of its own. The subs' own trims and delays (arc, end-fire, cardioid) shape the coverage. Best for a sub array: below about 100 Hz panning hardly localises, and moving delays would smear the array's pattern."
        case .delay: return "Level and delay per sub from the source's position, as a Delay group. For subs spread around a room, time-aligned with the mains near each source; the array's pattern moves as sources move."
        case .dbap: return "Level from each sub's distance to the source, with no delays. For subs spread around a room."
        case .pan: return "A console pan pot across the subs, left to right: for a left and a right sub stack, or L, C and R."
        }
    }
}

/// The LFE group's row in the Speakers list: always there, never deleted.
struct LFEGroupRow: View {
    let state: ShowState

    var body: some View {
        let n = state.system.lfeSpeakers.filter { state.speaker($0) != nil }.count
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4).fill(Color.gray)
                .overlay(Text("LFE").font(.system(size: 7, weight: .bold)).foregroundStyle(.white))
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("LFE").lineLimit(1)
                Text("\(state.system.lfeMode.title) · \(n) sub\(n == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(n == 0 ? Color.orange : Color.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(String(format: "%+.1f dB", state.system.lfeGainDB)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
        .help("The subs, fed by each source's LFE send. Always here.")
    }
}

/// The LFE group: its algorithm, level and subs.
struct LFEGroupInspector: View {
    @ObservedObject var model: EngineModel
    let state: ShowState

    var body: some View {
        let sys = state.system
        Form {
            Section {
                Picker("Algorithm", selection: Binding(get: { sys.lfeMode }, set: { m in model.apply(.setLFE(mode: m, gainDB: sys.lfeGainDB)) })) {
                    ForEach(LFEMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent("Level") {
                    LevelSlider(value: sys.lfeGainDB, range: -40...20, step: 0.5, unit: "dB") { v in
                        model.apply(.setLFE(mode: sys.lfeMode, gainDB: v))
                    }
                }
                if sys.lfeSpeakers.isEmpty {
                    Label("No subs yet: tick them below.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                }
            } header: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.gray).frame(width: 14, height: 14)
                    Text("LFE").font(.headline)
                }
            } footer: {
                Text(sys.lfeMode.explanation + " Each source's LFE send is in its inspector and in the Sends window's LFE column.")
            }
            Section("Subs") {
                ForEach(sys.speakers.sorted { $0.number < $1.number }) { s in
                    Toggle(isOn: Binding(get: { sys.lfeSpeakers.contains(s.id) }, set: { on in
                        var list = sys.lfeSpeakers.filter { $0 != s.id }
                        if on { list.append(s.id) }
                        let order = sys.speakers.sorted { $0.number < $1.number }.map(\.id)
                        model.apply(.setLFESpeakers(speakers: order.filter { list.contains($0) }))
                    })) {
                        HStack(spacing: 4) {
                            Text(s.label)
                            Text("out \(s.output)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// An output group in the sidebar's Speakers list.
struct OutputGroupRow: View {
    let group: SpeakerGroup
    let state: ShowState

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4).fill(group.color)
                .overlay(Text("\(group.number)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white))
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(state.isPlayable(group) ? Color.secondary : Color.orange).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(String(format: "%+.1f dB", group.gainDB)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    private var detail: String {
        let n = group.speakers.filter { state.speaker($0) != nil }.count
        var parts = [group.renderer.title, "\(n) speaker\(n == 1 ? "" : "s")"]
        if group.dimensions == 2 { parts.append("2D") }
        if !state.isPlayable(group) { parts.append(group.renderer == .vbap ? "needs 2 speakers" : "needs speakers") }
        return parts.joined(separator: " · ")
    }
}

/// An output group: its name, algorithm and the algorithm's settings, level and speakers.
struct OutputGroupInspector: View {
    @ObservedObject var model: EngineModel
    let state: ShowState
    let group: SpeakerGroup
    @Binding var selection: Selection?
    @State private var name = ""
    @State private var deleting = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name).onSubmit { if !name.isEmpty { set { $0.name = name } } }
                Picker("Algorithm", selection: Binding(get: { group.renderer }, set: { r in set { $0.renderer = r } })) {
                    ForEach(Renderer.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent("Level") {
                    LevelSlider(value: group.gainDB, range: -40...10, step: 0.5, unit: "dB") { v in set { $0.gainDB = v } }
                }
                if !state.isPlayable(group) {
                    Label(group.renderer == .vbap ? "VBAP needs at least 2 speakers; it plays nothing until then."
                          : "No speakers yet; it plays nothing until then.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.caption)
                }
            } header: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(group.color).frame(width: 14, height: 14)
                    Text("Output group \(group.number)").font(.headline)
                }
            } footer: {
                Text(group.renderer.explanation)
            }
            Section(group.renderer.title) { settings }
            Section {
                ForEach(state.system.speakers.sorted { $0.number < $1.number }) { s in speakerRow(s) }
            } header: {
                Text("Speakers")
            } footer: {
                Text("The number beside a speaker is its trim in this group (drag, double-click for 0 dB). "
                     + "A speaker can be in one Delay group only, and in any number of others.")
            }
            Section {
                Button("Delete group", role: .destructive) { deleting = true }
            }
        }
        .formStyle(.grouped)
        .onAppear { name = group.name }
        .onChange(of: group.id) { _, _ in name = group.name }
        .onChange(of: group.name) { _, n in name = n }
        .confirmationDialog("Delete \(group.name)?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete group", role: .destructive) {
                model.apply(.removeGroup(id: group.id))
                selection = nil
            }
        } message: {
            Text("Every source's send to it goes too, also in snapshots.")
        }
    }

    @ViewBuilder
    private var settings: some View {
        switch group.renderer {
        case .delay:
            flatPicker
            LabeledContent("Precedence") {
                LevelSlider(value: group.precedenceMS, range: 0...50, step: 0.5, unit: "ms") { v in set { $0.precedenceMS = v } }
            }
            .help("How long after the natural sound the speakers arrive (typically 5 to 15 ms)")
            rolloff
            optionalDistance("Reference distance", value: group.referenceDistance, auto: "nearest speaker", fallback: 5,
                             help: "Within this distance of a speaker the level stays at its trim") { v in set { $0.referenceDistance = v } }
            optionalDistance("Distance offset", value: group.distanceOffset, auto: "nearest speaker", fallback: 0,
                             help: "Distance taken off every speaker's delay; automatic leaves the nearest with only the precedence") { v in
                set { $0.distanceOffset = v }
            }
        case .vbap:
            Picker("Dimensions", selection: Binding(get: { group.dimensions }, set: { v in set { $0.dimensions = v } })) {
                Text("Automatic").tag(Int?.none)
                Text("2D (flat: azimuth and distance in plan)").tag(Int?.some(2))
                Text("3D (with height)").tag(Int?.some(3))
            }
            directional
        case .dbap:
            flatPicker
            LabeledContent("Blur") {
                LevelSlider(value: group.blur, range: 0...5, step: 0.1, unit: "m") { v in set { $0.blur = v } }
            }
            .help("Keeps one speaker from taking everything when a source sits on it")
            LabeledContent("Roll-off") {
                LevelSlider(value: group.rolloffDB, range: 0...12, step: 0.5, unit: "dB", format: { String(format: "%.1f dB per doubling", $0) }) { v in
                    set { $0.rolloffDB = v }
                }
            }
        case .knn:
            flatPicker
            LabeledContent("Neighbours (K)") {
                Stepper(value: Binding(get: { group.neighbours }, set: { v in set { $0.neighbours = max(1, v) } }),
                        in: 1...max(1, group.speakers.count)) {
                    Text("\(group.neighbours)").monospacedDigit()
                }
            }
            .help("How many of the nearest speakers may play")
            LabeledContent("Spread") {
                LevelSlider(value: group.spread, range: 0...180, step: 1, unit: "°") { v in set { $0.spread = v } }
            }
            .help("How far (in degrees, from the nearest speaker) the other neighbours still play; 0 plays only the nearest")
            directional
        case .spcap:
            flatPicker
            LabeledContent("Tightness") {
                LevelSlider(value: group.tightness, range: 1...20, step: 0.5, unit: "", format: { String(format: "%.1f", $0) }) { v in
                    set { $0.tightness = v }
                }
            }
            .help("1 spreads a source over every speaker in front of it; higher narrows it")
            directional
        case .pan:
            Picker("Pan law", selection: Binding(get: { group.panLawDB }, set: { v in set { $0.panLawDB = v } })) {
                Text("-3 dB (constant power)").tag(3.0)
                Text("-4.5 dB").tag(4.5)
                Text("-6 dB (linear)").tag(6.0)
            }
            .help("How far down each speaker is with the source halfway between them")
        }
    }

    /// 2D or 3D for Delay, DBAP, KNN and SPCAP (none is 3D).
    private var flatPicker: some View {
        Picker("Dimensions", selection: Binding(get: { group.dimensions == 2 ? 2 : 3 }, set: { v in set { $0.dimensions = v == 2 ? 2 : nil } })) {
            Text("3D (with height)").tag(3)
            Text("2D (flat: azimuth and distance in plan)").tag(2)
        }
    }

    private var rolloff: some View {
        LabeledContent("Roll-off") {
            LevelSlider(value: group.rolloff, range: 0...2, step: 0.1, unit: "",
                        format: { String(format: "%.1f (%.0f dB per doubling)", $0, $0 * 6.02) }) { v in set { $0.rolloff = v } }
        }
    }

    /// Roll-off, reference distance and the listening point, for the panners that work by direction.
    @ViewBuilder
    private var directional: some View {
        rolloff
        optionalDistance("Reference distance", value: group.referenceDistance, auto: "speakers' mean distance", fallback: 5,
                         help: "Sources further than this from the listening point roll off") { v in set { $0.referenceDistance = v } }
        Toggle("Pan around the listener", isOn: Binding(
            get: { group.reference == nil },
            set: { on in set { $0.reference = on ? nil : state.system.listener.position } }))
        if let r = group.reference {
            HStack {
                NumberField(title: "x", value: r.x) { v in set { $0.reference = Position(v, r.y, r.z) } }
                NumberField(title: "y", value: r.y) { v in set { $0.reference = Position(r.x, v, r.z) } }
                NumberField(title: "z", value: r.z) { v in set { $0.reference = Position(r.x, r.y, v) } }
            }
            .help("This group's own listening point, in metres")
        }
    }

    private func optionalDistance(_ title: String, value: Double?, auto: String, fallback: Double, help: String,
                                  _ change: @escaping (Double?) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("\(title): automatic (\(auto))", isOn: Binding(get: { value == nil }, set: { change($0 ? nil : fallback) }))
            if let value {
                NumberField(title: "\(title) (m)", value: value) { v in change(max(0, v)) }
            }
        }
        .help(help)
    }

    private func speakerRow(_ s: Speaker) -> some View {
        let member = group.speakers.contains(s.id)
        let trim = group.weightsDB[s.id.uuidString] ?? 0
        return HStack {
            Toggle(isOn: Binding(get: { member }, set: { model.setSpeakers([s.id], of: group, $0) })) {
                HStack(spacing: 4) {
                    Text(s.label)
                    Text("out \(s.output)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if member {
                DragValue(value: trim, range: -40...10, step: 0.5, reset: 0, text: { String(format: "%+.1f dB", $0) },
                          help: "\(s.label)'s trim in \(group.name)") { v in
                    set { $0.weightsDB[s.id.uuidString] = v == 0 ? nil : v }
                }
                .frame(width: 64)
            }
        }
    }

    private func set(_ change: (inout SpeakerGroup) -> Void) {
        var g = group
        change(&g)
        if g != group { model.apply(.setGroup(group: g)) }
    }
}
#endif

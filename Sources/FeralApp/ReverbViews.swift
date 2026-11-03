#if canImport(SwiftUI) && os(macOS)
import FeralControl
import FeralScene
import SwiftUI

extension Room {
    var color: Color { Color(hex: colour) ?? Color.pick(number + 3) }
}

/// A room in the sidebar's Rooms list.
struct RoomRow: View {
    let room: Room
    let state: ShowState

    var body: some View {
        let users = state.show.sources.filter { $0.reverb?.room == room.id }.count
        HStack(spacing: 8) {
            Image(systemName: "building.columns").foregroundStyle(room.color)
            Text(room.label).lineLimit(1)
            if room.mute { Text("muted").font(.caption).foregroundStyle(.orange) }
            Spacer()
            Text(String(format: "%.1f s", room.decayS)).monospacedDigit().foregroundStyle(.secondary)
            Text("\(users) src").font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
        }
    }
}

/// A source's room, its send to the room's tail and its early reflections.
struct ReverbSection: View {
    @ObservedObject var model: EngineModel
    let state: ShowState
    let source: Source

    var body: some View {
        let r = source.reverb ?? .off
        Section {
            Picker("Room", selection: Binding(get: { r.room }, set: { room in set { $0.room = room } })) {
                Text("None").tag(UUID?.none)
                ForEach(state.show.rooms) { room in Text(room.label).tag(UUID?.some(room.id)) }
            }
            if r.room != nil {
                LabeledContent("Reverb send") {
                    LevelSlider(value: r.sendDB, range: -40...10, step: 0.5, unit: "dB") { v in set { $0.sendDB = v } }
                }
                .help("The source's send to the room's tail. Distance modelling does not lower it, so a farther source sounds farther away.")
                Toggle("Early reflections", isOn: Binding(get: { r.early }, set: { on in set { $0.early = on } }))
                    .help("The room's walls reflecting this source: 16 reflections that move with it, panned over the room's speakers")
                if r.early {
                    LabeledContent("Reflections") {
                        LevelSlider(value: r.earlyDB, range: -40...10, step: 0.5, unit: "dB") { v in set { $0.earlyDB = v } }
                    }
                }
            }
        } header: {
            Text("Reverb")
        } footer: {
            if state.show.rooms.isEmpty {
                Text("Add a room in the sidebar's Rooms list first.")
            } else if state.stereoPartner(of: source.id) != nil {
                Text("A stereo pair's two sides share their reverb settings.")
            }
        }
    }

    private func set(_ change: (inout SourceReverb) -> Void) {
        var r = source.reverb ?? SourceReverb(room: nil)
        change(&r)
        model.update(source.id, SourceValues(reverb: r))
    }
}

/// A room: its size, decay, levels, walls and speakers.
struct RoomInspector: View {
    @ObservedObject var model: EngineModel
    let state: ShowState
    let room: Room
    @Binding var selection: Selection?
    @State private var name = ""
    @State private var deleting = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name).onSubmit { set { $0.name = name.isEmpty ? "Room \(room.number)" : name } }
                Toggle("Mute", isOn: Binding(get: { room.mute }, set: { m in set { $0.mute = m } }))
                Menu("Preset") {
                    ForEach(Room.Preset.allCases, id: \.self) { p in
                        Button(p.title) { model.apply(.setRoom(room: room.with(p))) }
                    }
                }
                .help("Sets the size, decay, walls and pre-delay to a typical room; levels and speakers stay")
            } header: {
                HStack(spacing: 8) {
                    Image(systemName: "building.columns").foregroundStyle(room.color)
                    Text("Room \(room.number)").font(.headline)
                    Text(room.name).foregroundStyle(.secondary)
                }
            }
            Section("Levels") {
                LabeledContent("Tail") {
                    LevelSlider(value: room.levelDB, range: -40...10, step: 0.5, unit: "dB") { v in set { $0.levelDB = v } }
                }
                LabeledContent("Reflections") {
                    LevelSlider(value: room.earlyDB, range: -40...10, step: 0.5, unit: "dB") { v in set { $0.earlyDB = v } }
                }
            }
            Section {
                LabeledContent("Decay") {
                    HStack {
                        LevelSlider(value: min(room.decayS, 12), range: 0.1...12, step: 0.1, unit: "s") { v in set { $0.decayS = v } }
                        NumberField(title: "s", value: room.decayS) { v in set { $0.decayS = min(max(v, 0.1), 30) } }
                            .labelsHidden()
                            .frame(width: 50)
                    }
                }
                .help("RT60 in the mids: the time the tail takes to fall by 60 dB (0.1 to 30 s; the slider goes to 12, type more)")
                LabeledContent("Lows") {
                    LevelSlider(value: room.lowDecay, range: 0.25...3, step: 0.05, unit: "",
                                format: { String(format: "%.2f× (%.1f s)", $0, $0 * room.decayS) }) { v in set { $0.lowDecay = v } }
                }
                .help("The decay below 177 Hz, as a multiple of the mid decay: above 1 is warmer")
                LabeledContent("Highs") {
                    LevelSlider(value: room.highDecay, range: 0.1...2, step: 0.05, unit: "",
                                format: { String(format: "%.2f× (%.1f s)", $0, $0 * room.decayS) }) { v in set { $0.highDecay = v } }
                }
                .help("The decay above 5.7 kHz, as a multiple of the mid decay: below 1 is darker, as real rooms are")
                LabeledContent("Pre-delay") {
                    LevelSlider(value: room.predelayMS, range: 0...200, step: 1, unit: "ms") { v in set { $0.predelayMS = v } }
                }
                .help("Extra time before the tail starts (the early reflections are not delayed)")
                LabeledContent("Diffusion") {
                    LevelSlider(value: room.diffusion, range: 0...1, step: 0.05, unit: "", format: { String(format: "%.0f %%", $0 * 100) }) { v in
                        set { $0.diffusion = v }
                    }
                }
                .help("How smeared the tail starts: low keeps the first echoes distinct, high makes it dense at once")
                LabeledContent("Modulation") {
                    LevelSlider(value: room.modulation, range: 0...1, step: 0.05, unit: "", format: { String(format: "%.0f %%", $0 * 100) }) { v in
                        set { $0.modulation = v }
                    }
                }
                .help("How much the tail's delay lines wander: smooths its colour; 0 can sound metallic")
            } header: {
                Text("Tail")
            }
            Section {
                LabeledContent("Width (m)") { NumberField(title: "m", value: room.width) { v in set { $0.width = v } }.labelsHidden() }
                LabeledContent("Depth (m)") { NumberField(title: "m", value: room.depth) { v in set { $0.depth = v } }.labelsHidden() }
                LabeledContent("Height (m)") { NumberField(title: "m", value: room.height) { v in set { $0.height = v } }.labelsHidden() }
                LabeledContent("Walls") {
                    LevelSlider(value: room.absorption, range: 0...1, step: 0.05, unit: "", format: wallLabel) { v in
                        set { $0.absorption = v }
                    }
                }
                .help("How much the walls absorb: hard walls give loud, bright reflections; soft ones quiet, dull ones")
                Toggle("Centred on the listener", isOn: Binding(get: { room.centre == nil }, set: { on in
                    set { $0.centre = on ? nil : Position(state.system.listener.position.x, state.system.listener.position.y, 0) }
                }))
                if let c = room.centre {
                    LabeledContent("Floor centre x") { NumberField(title: "m", value: c.x) { v in set { $0.centre?.x = v } }.labelsHidden() }
                    LabeledContent("Floor centre y") { NumberField(title: "m", value: c.y) { v in set { $0.centre?.y = v } }.labelsHidden() }
                    LabeledContent("Floor height") { NumberField(title: "m", value: c.z) { v in set { $0.centre?.z = v } }.labelsHidden() }
                }
            } header: {
                Text("Room (early reflections)")
            } footer: {
                Text("The box the reflections bounce in. Its size also sets the tail's density.")
            }
            Section {
                Toggle("Use speaker subset", isOn: Binding(get: { room.useSpeakerSubset }, set: { on in
                    set {
                        $0.useSpeakerSubset = on
                        // Start the subset from every speaker it plays on now.
                        if on && $0.speakers.isEmpty {
                            $0.speakers = state.system.speakers.filter { !state.system.lfeSpeakers.contains($0.id) }.map(\.id)
                        }
                    }
                }))
                if room.useSpeakerSubset {
                    ForEach(state.system.speakers.sorted { $0.number < $1.number }) { s in
                        Toggle(s.label, isOn: Binding(get: { room.speakers.contains(s.id) }, set: { on in
                            set { r in
                                if on { if !r.speakers.contains(s.id) { r.speakers.append(s.id) } } else { r.speakers.removeAll { $0 == s.id } }
                            }
                        }))
                    }
                }
            } header: {
                Text("Speakers")
            } footer: {
                Text(room.useSpeakerSubset ? "The tail and reflections play only on the ticked speakers."
                                           : "The tail and reflections play on every speaker but the LFE ones.")
            }
            Section {
                let users = state.show.sources.filter { $0.reverb?.room == room.id }
                Text(users.isEmpty ? "No source plays into it yet (pick the room in a source's Reverb section)."
                                   : users.map(\.label).joined(separator: ", "))
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Every source into it") {
                        let updates = state.show.sources.map { s -> SourceUpdate in
                            var r = s.reverb ?? SourceReverb(room: room.id)
                            r.room = room.id
                            return SourceUpdate(id: s.id, values: SourceValues(reverb: r))
                        }
                        model.apply(.updateSources(updates: updates))
                    }
                    Spacer()
                    Button("Delete room…", role: .destructive) { deleting = true }
                }
            } header: {
                Text("Sources")
            }
        }
        .formStyle(.grouped)
        .onAppear { name = room.name }
        .onChange(of: room.id) { _ in name = room.name }
        .onChange(of: room.name) { n in name = n }
        .confirmationDialog("Delete \(room.label)?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete room", role: .destructive) {
                model.apply(.removeRoom(id: room.id))
                selection = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its sources play into no room, also in snapshots.")
        }
    }

    private func wallLabel(_ v: Double) -> String {
        let percent = String(format: "%.0f %%", v * 100)
        if v < 0.2 { return "hard, " + percent }
        return v < 0.5 ? percent : "soft, " + percent
    }

    private func set(_ change: (inout Room) -> Void) {
        var r = room
        change(&r)
        if r != room { model.apply(.setRoom(room: r)) }
    }
}
#endif

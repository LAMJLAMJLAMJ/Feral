#if canImport(SwiftUI) && os(macOS)
import FeralControl
import FeralScene
import SwiftUI

/// A console-style mixer: a channel strip per source (fader, input meter, mute) and per source
/// group (fader and mute, like a VCA). It sits under the plan (⇧⌘X) or in its own window (Window >
/// Mixer, ⌥⌘X). Every move is a request to the engine, so other clients see it at once.
struct MixerView: View {
    @ObservedObject var model: EngineModel
    @ObservedObject var meters: MeterStore
    @Binding var selection: Selection?
    /// In the main window: the hide button and a fixed height. In its own window: neither.
    var docked: Binding<Bool>?
    @AppStorage("mixerShowsGroups") private var groupsFirst = false

    static let dockedHeight: CGFloat = 290

    var body: some View {
        VStack(spacing: 0) {
            header
            if docked?.wrappedValue ?? true {
                if let state = model.state {
                    strips(state)
                } else {
                    Text("Not connected to the engine").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(height: fixedHeight)
        .background(.bar)
    }

    private var fixedHeight: CGFloat? {
        guard let docked else { return nil }
        return docked.wrappedValue ? Self.dockedHeight : nil
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let docked {
                Button { withAnimation(.easeInOut(duration: 0.15)) { docked.wrappedValue.toggle() } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: docked.wrappedValue ? "chevron.down" : "chevron.right").font(.caption2.bold())
                        Text("MIXER").font(.caption2.bold())
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide or show the mixer (⇧⌘X)")
            }
            if docked?.wrappedValue ?? true {
                Picker("Show", selection: $groupsFirst) {
                    Text("Sources").tag(false)
                    Text("Groups").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
                Text("Drag a fader; double-click it for 0 dB. Click a name to select it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func strips(_ state: ShowState) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 2) {
                if groupsFirst {
                    if state.show.sourceGroups.isEmpty {
                        Text("No source groups yet. Make one with the Group button in the Sources list (⇧⌘G).")
                            .foregroundStyle(.secondary).padding()
                    }
                    ForEach(state.show.sourceGroups) { g in
                        GroupStrip(model: model, group: g, state: state, selected: selection == .sourceGroup(g.id)) {
                            selection = .sourceGroup(g.id)
                        }
                    }
                } else {
                    if state.show.sources.isEmpty {
                        Text("No sources yet. Add one with + in the Sources list (⇧⌘N).").foregroundStyle(.secondary).padding()
                    }
                    ForEach(state.show.sources) { s in
                        SourceStrip(model: model, meters: meters, source: s, state: state, selected: selection == .source(s.id)) {
                            selection = .source(s.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// One source: name, groups, fader beside its input meter, level, mute.
private struct SourceStrip: View {
    @ObservedObject var model: EngineModel
    @ObservedObject var meters: MeterStore
    let source: Source
    let state: ShowState
    let selected: Bool
    let select: () -> Void

    var body: some View {
        let groups = state.sourceGroups(of: source.id)
        let groupGain = groups.reduce(0) { $0 + $1.gainDB }
        let groupMuted = groups.contains { $0.mute }
        StripFrame(selected: selected) {
            StripTitle(number: "\(source.number)", name: source.name ?? "Source \(source.number)", color: source.color, select: select)
            HStack(spacing: 2) {
                ForEach(groups) { g in
                    RoundedRectangle(cornerRadius: 2).fill(g.color).frame(width: 10, height: 4).help(g.label)
                }
            }
            .frame(height: 4)
            HStack(spacing: 4) {
                Fader(value: source.gainDB) { model.update(source.id, SourceValues(gainDB: $0)) }
                MeterBar(channel: meters.input(source.input), vertical: true, clear: { meters.clearClip(input: source.input) })
                    .frame(width: 7)
            }
            .frame(maxHeight: .infinity)
            Text(Fader.text(source.gainDB)).font(.caption.monospacedDigit())
            if !groups.isEmpty && (groupGain != 0 || groupMuted) {
                Text(groupMuted ? "group muted" : "grp " + Fader.text(groupGain))
                    .font(.system(size: 8).monospacedDigit()).foregroundStyle(groupMuted ? Color.red : Color.secondary)
            }
            MuteButton(on: source.mute) { model.update(source.id, SourceValues(mute: !source.mute)) }
            Text("in \(source.input)").font(.system(size: 8)).foregroundStyle(.secondary)
        }
    }
}

/// One source group: its fader (added to every member's gain) and mute.
private struct GroupStrip: View {
    @ObservedObject var model: EngineModel
    let group: SourceGroup
    let state: ShowState
    let selected: Bool
    let select: () -> Void

    var body: some View {
        let count = group.sources.filter { state.source($0) != nil }.count
        StripFrame(selected: selected) {
            StripTitle(number: "G\(group.number)", name: group.name, color: group.color, select: select)
            Spacer().frame(height: 4)
            Fader(value: group.gainDB) { v in
                guard var g = model.state?.sourceGroup(group.id) else { return }
                g.gainDB = v
                model.setSourceGroup(g)
            }
            .frame(maxHeight: .infinity)
            Text(Fader.text(group.gainDB)).font(.caption.monospacedDigit())
            MuteButton(on: group.mute) {
                guard var g = model.state?.sourceGroup(group.id) else { return }
                g.mute.toggle()
                model.setSourceGroup(g)
            }
            Text("\(count) source\(count == 1 ? "" : "s")").font(.system(size: 8)).foregroundStyle(.secondary)
        }
    }
}

private struct StripFrame<Content: View>: View {
    let selected: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 4) { content }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .frame(width: 68)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(selected ? 0.12 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
    }
}

private struct StripTitle: View {
    let number: String
    let name: String
    let color: Color
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 1) {
                Text(number).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(color))
                Text(name).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center)
                    .frame(height: 26)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Select \(name)")
    }
}

private struct MuteButton: View {
    let on: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Text("M").font(.system(size: 11, weight: .bold))
                .frame(width: 36, height: 20)
                .foregroundStyle(on ? Color.white : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? Color.red : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(on ? "Unmute" : "Mute")
    }
}

/// A vertical fader with a console law: 0 dB three quarters of the way up, +10 at the top and the
/// bottom at -80 (shown as -∞). It follows the mouse from its own copy while dragged, sending up to
/// 30 changes a second and the last one on release. Double-click sets 0 dB.
struct Fader: View {
    let value: Double
    let set: (Double) -> Void
    @State private var dragged: Double?
    /// The fader position when the drag started, so the cap moves with the mouse rather than jumping.
    @State private var startPosition: Double?
    @State private var lastSent = Date.distantPast

    /// Fader position (0 bottom, 1 top) to dB, piecewise linear.
    static let law: [(Double, Double)] = [(0, -80), (0.12, -50), (0.3, -30), (0.5, -15), (0.75, 0), (1, 10)]

    static func dB(at p: Double) -> Double {
        let p = min(max(p, 0), 1)
        for k in 1..<law.count where p <= law[k].0 {
            let (p0, d0) = law[k - 1], (p1, d1) = law[k]
            return d0 + (p - p0) / (p1 - p0) * (d1 - d0)
        }
        return law.last!.1
    }

    static func position(of dB: Double) -> Double {
        let d = min(max(dB, law.first!.1), law.last!.1)
        for k in 1..<law.count where d <= law[k].1 {
            let (p0, d0) = law[k - 1], (p1, d1) = law[k]
            return p0 + (d - d0) / (d1 - d0) * (p1 - p0)
        }
        return 1
    }

    static func text(_ dB: Double) -> String { dB <= -79.9 ? "-∞" : String(format: "%+.1f", dB) }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let capH: CGFloat = 22
            let travel = max(h - capH, 1)
            let shown = dragged ?? value
            let y = (1 - CGFloat(Self.position(of: shown))) * travel
            ZStack(alignment: .top) {
                // Slot and scale marks.
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.25))
                    .frame(width: 4, height: travel)
                    .offset(y: capH / 2)
                ForEach([10.0, 0, -10, -20, -30, -50], id: \.self) { mark in
                    Rectangle().fill(Color.secondary.opacity(mark == 0 ? 0.8 : 0.4))
                        .frame(width: mark == 0 ? 22 : 12, height: 1)
                        .offset(y: capH / 2 + (1 - CGFloat(Self.position(of: mark))) * travel)
                }
                // The cap.
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.6)], startPoint: .top, endPoint: .bottom))
                    .overlay(Rectangle().fill(Color.black.opacity(0.7)).frame(height: 2))
                    .frame(width: 26, height: capH)
                    .shadow(radius: 1, y: 1)
                    .offset(y: y)
            }
            .frame(width: geo.size.width, height: h, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        // The cap follows the mouse from where it was, rather than jumping to the click.
                        let start = startPosition ?? Self.position(of: value)
                        startPosition = start
                        let p = start - Double(g.translation.height / travel)
                        let v = (Self.dB(at: p) * 10).rounded() / 10
                        dragged = v
                        if Date().timeIntervalSince(lastSent) >= 1.0 / 30 { lastSent = Date(); set(v) }
                    }
                    .onEnded { _ in
                        if let v = dragged { set(v) }
                        dragged = nil
                        startPosition = nil
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { set(0) })
        }
        .frame(width: 30)
        .frame(minHeight: 80)
    }
}

/// Window > Mixer.
struct OpenMixerButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Mixer") { openWindow(id: "mixer") }
            .keyboardShortcut("x", modifiers: [.command, .option])
    }
}

/// The mixer's own window, with its own selection.
struct MixerWindow: View {
    @ObservedObject var model: EngineModel
    @State private var selection: Selection?

    var body: some View {
        MixerView(model: model, meters: model.meters, selection: $selection, docked: nil)
            .frame(minWidth: 400, minHeight: 300)
    }
}
#endif

#if canImport(SwiftUI) && os(macOS)
import FeralControl
import FeralScene
import SwiftUI

/// Audio > Patch (⌥⌘P): a crosspoint matrix between the sound card's channels and Feral's, with an
/// Inputs tab (card inputs into Feral inputs, which sources play) and an Outputs tab (Feral outputs,
/// which speakers are on, to card outputs). Changes are drafted here and sent with Apply, since the
/// engine reopens the audio on a new patch (a short gap).
struct PatchView: View {
    @ObservedObject var model: EngineModel
    @ObservedObject var meters: MeterStore
    @AppStorage("patchOutputsTab") private var outputsTab = false
    @State private var draftIn: [Int]?
    @State private var draftOut: [Int]?
    @State private var showBlock = false
    @State private var applied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let patch = model.patch, let state = model.state {
                PatchMatrix(outputs: outputsTab, live: live(patch), patch: current(patch),
                            available: outputsTab ? patch.deviceOutputs : patch.deviceInputs,
                            deviceOpen: patch.device != nil, labels: labels(state, rows: live(patch).count),
                            meters: meters) { row, column, on in
                    set(row: row, column: column, on: on, patch)
                }
                .id(outputsTab)
            } else {
                ContentUnavailableView(model.connected ? "Waiting for the engine's patch" : "Not connected to the engine",
                                       systemImage: "square.grid.3x3",
                                       description: Text("The patch shows once the app is connected to the engine."))
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { model.refreshPatch() }
        .onChange(of: model.patch) { _, p in
            guard let p else { return }
            // Drop a draft once the engine has it (or it matches anyway).
            if draftIn == p.inputs { draftIn = nil }
            if draftOut == p.outputs { draftOut = nil }
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Tab", selection: $outputsTab) {
                Text("Inputs").tag(false)
                Text("Outputs").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            Text(deviceLine).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button("Patch a block…") { showBlock = true }
                .popover(isPresented: $showBlock, arrowEdge: .bottom) {
                    if let patch = model.patch {
                        BlockPatch(outputs: outputsTab, rows: live(patch).count,
                                   available: outputsTab ? patch.deviceOutputs : patch.deviceInputs) { from, to, first in
                            block(from: from, to: to, first: first, patch)
                            showBlock = false
                        }
                    }
                }
                .disabled(model.patch == nil)
                .help("Patch a run of Feral \(outputsTab ? "outputs" : "inputs") in order, or unpatch them")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if changes > 0 {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.orange)
                Text("\(changes) change\(changes == 1 ? "" : "s") not applied. Applying reopens the audio, a short gap.")
                    .font(.callout)
            } else if applied, let e = model.lastError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(e).font(.callout).lineLimit(2)
            } else {
                Text("Click a crosspoint to patch it, or drag across to patch several. Click a patched one to unpatch it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revert") { draftIn = nil; draftOut = nil }
                .disabled(changes == 0)
            Button("Apply") {
                applied = true
                model.lastError = nil
                model.setPatch(inputs: draftIn, outputs: draftOut)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(changes == 0 || !model.connected)
            .help("Send the patch to the engine and save it in engine.json (⌘↩)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var deviceLine: String {
        guard let p = model.patch else { return "" }
        guard let name = p.device else { return "No sound card open" }
        return "\(name) · \(p.deviceInputs) in / \(p.deviceOutputs) out"
    }

    /// Crosspoints in the drafts that differ from the engine's patch, both tabs.
    private var changes: Int {
        guard let p = model.patch else { return 0 }
        func diff(_ a: [Int]?, _ b: [Int]) -> Int {
            guard let a else { return 0 }
            return zip(a, b).filter { $0 != $1 }.count
        }
        return diff(draftIn, p.inputs) + diff(draftOut, p.outputs)
    }

    // MARK: Editing

    private func live(_ p: PatchInfo) -> [Int] { outputsTab ? p.outputs : p.inputs }

    private func current(_ p: PatchInfo) -> [Int] {
        // A draft from before the engine's channel count changed no longer fits.
        guard let d = outputsTab ? draftOut : draftIn, d.count == live(p).count else { return live(p) }
        return d
    }

    private func store(_ list: [Int]) {
        if outputsTab { draftOut = list } else { draftIn = list }
    }

    /// Patches (or unpatches) Feral channel `row` to card channel `column`, both from 1. A Feral
    /// channel takes one card channel; a card output takes one Feral output.
    private func set(row: Int, column: Int, on: Bool, _ p: PatchInfo) {
        var list = current(p)
        guard list.indices.contains(row - 1) else { return }
        if on {
            if outputsTab { for j in list.indices where list[j] == column { list[j] = 0 } }
            list[row - 1] = column
        } else if list[row - 1] == column {
            list[row - 1] = 0
        }
        store(list)
    }

    /// Feral channels from...to onto card channels in order from `first`; first 0 unpatches them.
    private func block(from: Int, to: Int, first: Int, _ p: PatchInfo) {
        var list = current(p)
        for (k, row) in (from...to).enumerated() where list.indices.contains(row - 1) {
            let column = first == 0 ? 0 : first + k
            if outputsTab && column > 0 { for j in list.indices where list[j] == column { list[j] = 0 } }
            list[row - 1] = column
        }
        store(list)
    }

    /// The sources on each Feral input, or the speaker on each output.
    private func labels(_ state: ShowState, rows: Int) -> [String] {
        var names = [String](repeating: "", count: rows)
        if outputsTab {
            for s in state.system.speakers where names.indices.contains(s.output - 1) {
                names[s.output - 1] = s.name ?? "Speaker \(s.number)"
            }
        } else {
            for s in state.show.sources where names.indices.contains(s.input - 1) {
                let name = s.name ?? "Source \(s.number)"
                names[s.input - 1] = names[s.input - 1].isEmpty ? name : names[s.input - 1] + ", " + name
            }
        }
        return names
    }
}

/// "Feral inputs 1 to 26 from card input 33", or unpatch them.
private struct BlockPatch: View {
    let outputs: Bool
    let rows: Int
    let available: Int
    let apply: (_ from: Int, _ to: Int, _ first: Int) -> Void
    @State private var from = 1
    @State private var to = 1
    @State private var first = 1
    @State private var loaded = false

    var body: some View {
        Form {
            TextField("Feral \(outputs ? "outputs" : "inputs") from", value: $from, format: .number)
            TextField("to", value: $to, format: .number)
            TextField(outputs ? "onto card output" : "from card input", value: $first, format: .number)
            Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Unpatch them") { apply(lo, hi, 0) }
                Spacer()
                Button("Patch") { apply(lo, hi, max(first, 1)) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 300)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            to = max(1, min(rows, available > 0 ? available : rows))
        }
    }

    private var lo: Int { min(max(min(from, to), 1), max(rows, 1)) }
    private var hi: Int { min(max(max(from, to), 1), max(rows, 1)) }

    private var summary: String {
        let last = max(first, 1) + hi - lo
        let range = lo == hi ? "\(lo)" : "\(lo) to \(hi)"
        let card = lo == hi ? "\(max(first, 1))" : "\(max(first, 1)) to \(last)"
        var text = outputs ? "Feral outputs \(range) onto card outputs \(card)." : "Feral inputs \(range) from card inputs \(card)."
        if available > 0 && last > available { text += " The card has only \(available); the rest stay silent." }
        return text
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue = CGPoint.zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

/// The crosspoint grid: Feral channels down the side, card channels across the top. The headers
/// stay put while the grid scrolls, and only what is in view is drawn.
private struct PatchMatrix: View {
    let outputs: Bool
    /// The engine's patch and the draft: a card channel (from 1, 0 for none) per Feral channel.
    let live: [Int]
    let patch: [Int]
    /// The card's channels on this side; 0 while no card is open.
    let available: Int
    let deviceOpen: Bool
    let labels: [String]
    @ObservedObject var meters: MeterStore
    let change: (_ row: Int, _ column: Int, _ on: Bool) -> Void

    static let cell: CGFloat = 16
    static let rowHeader: CGFloat = 190
    static let columnHeader: CGFloat = 26

    @State private var scroll = CGPoint.zero
    @State private var hover: (row: Int, column: Int)?
    /// While dragging: patching (true) or unpatching (false), and the last cell touched.
    @State private var painting: Bool?
    @State private var lastCell: (row: Int, column: Int)?

    private var rows: Int { live.count }
    private var columns: Int {
        let used = max(patch.max() ?? 0, live.max() ?? 0)
        return max(deviceOpen ? available : 64, used, 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                corner
                Canvas { ctx, size in drawColumnHeader(ctx, size) }
                    .frame(height: Self.columnHeader)
            }
            Divider()
            HStack(spacing: 0) {
                Canvas { ctx, size in drawRowHeader(ctx, size) }
                    .frame(width: Self.rowHeader)
                Divider()
                grid
            }
            Divider()
            Text(readout).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 4)
        }
    }

    private var corner: some View {
        HStack(spacing: 4) {
            Text(outputs ? "FERAL OUTPUT ↓   CARD OUTPUT →" : "FERAL INPUT ↓   CARD INPUT →")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        }
        .frame(width: Self.rowHeader + 1, height: Self.columnHeader)
    }

    private var grid: some View {
        let cell = Self.cell
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, size in drawGrid(ctx, size) }
                .allowsHitTesting(false)
            ScrollView([.horizontal, .vertical]) {
                Color.clear
                    .frame(width: CGFloat(columns) * cell, height: CGFloat(rows) * cell)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ScrollOffsetKey.self, value: g.frame(in: .named("patchGrid")).origin)
                    })
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hover = cellAt(p)
                        case .ended: hover = nil
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in dragged(to: g.location) }
                            .onEnded { _ in painting = nil; lastCell = nil }
                    )
            }
            .coordinateSpace(name: "patchGrid")
            .onPreferenceChange(ScrollOffsetKey.self) { origin in
                scroll = CGPoint(x: -origin.x, y: -origin.y)
            }
        }
        .clipped()
    }

    private func cellAt(_ p: CGPoint) -> (row: Int, column: Int)? {
        let row = Int(p.y / Self.cell) + 1, column = Int(p.x / Self.cell) + 1
        guard (1...rows).contains(row), (1...columns).contains(column) else { return nil }
        return (row, column)
    }

    private func dragged(to p: CGPoint) {
        guard let c = cellAt(p) else { return }
        hover = c
        if let last = lastCell, last.row == c.row, last.column == c.column { return }
        lastCell = c
        let mode: Bool
        if let painting {
            mode = painting
        } else {
            // The first cell decides: on a patched crosspoint the drag unpatches, otherwise it patches.
            mode = patch[c.row - 1] != c.column
            painting = mode
        }
        change(c.row, c.column, mode)
    }

    // MARK: Drawing

    /// The rows and columns in view.
    private func visible(_ size: CGSize) -> (rows: ClosedRange<Int>, columns: ClosedRange<Int>) {
        let cell = Self.cell
        let r0 = max(Int(scroll.y / cell) + 1, 1), r1 = min(Int((scroll.y + size.height) / cell) + 1, rows)
        let c0 = max(Int(scroll.x / cell) + 1, 1), c1 = min(Int((scroll.x + size.width) / cell) + 1, columns)
        return (r0...max(r0, r1), c0...max(c0, c1))
    }

    private func x(_ column: Int) -> CGFloat { CGFloat(column - 1) * Self.cell - scroll.x }
    private func y(_ row: Int) -> CGFloat { CGFloat(row - 1) * Self.cell - scroll.y }

    private func drawGrid(_ ctx: GraphicsContext, _ size: CGSize) {
        guard rows > 0 else { return }
        let cell = Self.cell
        let v = visible(size)
        let width = min(CGFloat(columns) * cell - scroll.x, size.width)
        let height = min(CGFloat(rows) * cell - scroll.y, size.height)
        // Blocks of eight, shaded like a chessboard, to keep your place.
        for r in stride(from: ((v.rows.lowerBound - 1) / 8) * 8 + 1, through: v.rows.upperBound, by: 8) {
            for c in stride(from: ((v.columns.lowerBound - 1) / 8) * 8 + 1, through: v.columns.upperBound, by: 8)
            where ((r - 1) / 8 + (c - 1) / 8) % 2 == 1 {
                ctx.fill(Path(CGRect(x: x(c), y: y(r), width: cell * 8, height: cell * 8)),
                         with: .color(.secondary.opacity(0.07)))
            }
        }
        // Card channels it does not have.
        if deviceOpen && available < columns {
            ctx.fill(Path(CGRect(x: x(available + 1), y: 0, width: size.width, height: height)),
                     with: .color(.red.opacity(0.08)))
        }
        if let hover {
            ctx.fill(Path(CGRect(x: 0, y: y(hover.row), width: width, height: cell)), with: .color(.accentColor.opacity(0.12)))
            ctx.fill(Path(CGRect(x: x(hover.column), y: 0, width: cell, height: height)), with: .color(.accentColor.opacity(0.12)))
        }
        var lines = Path()
        for r in v.rows.lowerBound...min(v.rows.upperBound + 1, rows + 1) {
            lines.move(to: CGPoint(x: 0, y: y(r))); lines.addLine(to: CGPoint(x: width, y: y(r)))
        }
        for c in v.columns.lowerBound...min(v.columns.upperBound + 1, columns + 1) {
            lines.move(to: CGPoint(x: x(c), y: 0)); lines.addLine(to: CGPoint(x: x(c), y: height))
        }
        ctx.stroke(lines, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
        drawCrosspoints(ctx, v)
    }

    private func drawCrosspoints(_ ctx: GraphicsContext, _ v: (rows: ClosedRange<Int>, columns: ClosedRange<Int>)) {
        let cell = Self.cell
        for r in v.rows {
            let now = patch[r - 1], was = live[r - 1]
            if now > 0 && v.columns.contains(now) {
                let box = CGRect(x: x(now) + 3, y: y(r) + 3, width: cell - 6, height: cell - 6)
                let missing = deviceOpen && now > available
                let colour: Color = missing ? .red : (now == was ? .accentColor : .orange)
                ctx.fill(Path(roundedRect: box, cornerRadius: 2), with: .color(colour))
            }
            if was > 0 && was != now && v.columns.contains(was) {
                // Unpatched in the draft: an outline where it was.
                let box = CGRect(x: x(was) + 3.5, y: y(r) + 3.5, width: cell - 7, height: cell - 7)
                ctx.stroke(Path(roundedRect: box, cornerRadius: 2), with: .color(.orange), lineWidth: 1)
            }
        }
    }

    private func drawColumnHeader(_ ctx: GraphicsContext, _ size: CGSize) {
        guard rows > 0 else { return }
        let cell = Self.cell
        for c in visible(CGSize(width: size.width, height: cell)).columns {
            let centre = CGPoint(x: x(c) + cell / 2, y: size.height / 2)
            let on = hover?.column == c
            let missing = deviceOpen && c > available
            if on { ctx.fill(Path(CGRect(x: x(c), y: 0, width: cell, height: size.height)), with: .color(.accentColor.opacity(0.2))) }
            let text = Text("\(c)").font(.system(size: c >= 100 ? 7 : 8, weight: on ? .bold : .regular).monospacedDigit())
                .foregroundColor(missing ? .red : (c % 8 == 1 ? .primary : .secondary))
            ctx.draw(text, at: centre)
        }
    }

    private func drawRowHeader(_ ctx: GraphicsContext, _ size: CGSize) {
        guard rows > 0 else { return }
        let cell = Self.cell
        for r in visible(CGSize(width: cell, height: size.height)).rows {
            let mid = y(r) + cell / 2
            if hover?.row == r {
                ctx.fill(Path(CGRect(x: 0, y: y(r), width: size.width, height: cell)), with: .color(.accentColor.opacity(0.2)))
            }
            // Signal on the Feral channel.
            let level = (outputs ? meters.output(r) : meters.input(r))?.peak ?? MeterFrame.silence
            let dot = level > -20 ? Color.green : (level > -60 ? Color.green.opacity(0.45) : Color.secondary.opacity(0.2))
            ctx.fill(Path(ellipseIn: CGRect(x: 6, y: mid - 3, width: 6, height: 6)), with: .color(dot))
            ctx.draw(Text("\(r)").font(.system(size: 9, weight: .semibold).monospacedDigit()), at: CGPoint(x: 38, y: mid), anchor: .trailing)
            if !labels[r - 1].isEmpty {
                ctx.draw(Text(labels[r - 1]).font(.system(size: 9)).foregroundColor(.secondary),
                         at: CGPoint(x: 44, y: mid), anchor: .leading)
            }
            let card = patch[r - 1]
            let tag = card == 0 ? "–" : (outputs ? "→ \(card)" : "← \(card)")
            let colour: Color = card == 0 ? .secondary : (card != live[r - 1] ? .orange : (deviceOpen && card > available ? .red : .primary))
            // Cover a long name so the card channel stays readable.
            ctx.fill(Path(CGRect(x: size.width - 44, y: y(r), width: 44, height: cell)), with: .color(Color(nsColor: .windowBackgroundColor)))
            if hover?.row == r {
                ctx.fill(Path(CGRect(x: size.width - 44, y: y(r), width: 44, height: cell)), with: .color(.accentColor.opacity(0.2)))
            }
            ctx.draw(Text(tag).font(.system(size: 9).monospacedDigit()).foregroundColor(colour),
                     at: CGPoint(x: size.width - 6, y: mid), anchor: .trailing)
        }
    }

    private var readout: String {
        guard let hover else {
            let n = patch.filter { $0 > 0 }.count
            return "\(n) of \(rows) Feral \(outputs ? "outputs" : "inputs") patched"
        }
        let name = labels[hover.row - 1].isEmpty ? "" : " (\(labels[hover.row - 1]))"
        let feral = "Feral \(outputs ? "output" : "input") \(hover.row)\(name)"
        let card = "card \(outputs ? "output" : "input") \(hover.column)"
        let state = patch[hover.row - 1] == hover.column ? "patched" : "click to patch"
        let missing = deviceOpen && hover.column > available ? " · the card has only \(available)" : ""
        return outputs ? "\(feral) → \(card) · \(state)\(missing)" : "\(card) → \(feral) · \(state)\(missing)"
    }
}

/// Audio > Patch.
struct OpenPatchButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Patch…") { openWindow(id: "patch") }
            .keyboardShortcut("p", modifiers: [.command, .option])
    }
}
#endif

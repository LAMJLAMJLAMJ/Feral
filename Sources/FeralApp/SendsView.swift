#if canImport(SwiftUI) && os(macOS)
import FeralScene
import SwiftUI

/// Window > Sends (⌥⌘S): every source's sends to every speaker group (and the LFE) as one grid.
/// A stereo pair is one row and sets both sides. Click an empty cell to send at 0 dB, drag a level
/// up or down (Option for fine), double-click for 0 dB, right-click to remove it.
struct SendsView: View {
    @ObservedObject var model: EngineModel

    var body: some View {
        if let state = model.state {
            SendsGrid(model: model, state: state)
        } else {
            Text("Not connected").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SendsGrid: View {
    @ObservedObject var model: EngineModel
    let state: ShowState

    /// One row: a mono source, or a stereo pair (left first).
    private struct Row: Identifiable {
        let id: UUID
        let label: String
        let color: Color
        let sources: [Source]
        var first: Source { sources[0] }
    }

    private func makeRows() -> [Row] {
        state.show.sources.compactMap { s -> Row? in
            if let pair = model.stereoPair(of: s.id) {
                guard pair.left.id == s.id else { return nil }
                return Row(id: s.id, label: "\(pair.left.number)/\(pair.right.number) \(pair.group.name)", color: pair.group.color,
                           sources: [pair.left, pair.right])
            }
            return Row(id: s.id, label: s.label, color: s.color, sources: [s])
        }
    }

    private var hasLFE: Bool { !state.system.lfeSpeakers.isEmpty }
    private let cellWidth: CGFloat = 64

    var body: some View {
        let rows = makeRows()
        let groups = state.show.groups
        if groups.isEmpty || rows.isEmpty {
            Text(groups.isEmpty ? "No speaker groups yet" : "No sources yet")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 3) {
                    GridRow {
                        Text("Source").font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(groups) { g in
                            header(g.name, detail: g.renderer.title, color: g.color)
                                .contextMenu {
                                    Button("Send every source at 0 dB") { setAll(group: g.id, rows: rows, gainDB: 0) }
                                    Button("Remove every send to \(g.name)") { setAll(group: g.id, rows: rows, gainDB: nil) }
                                }
                        }
                        if hasLFE { header("LFE", detail: "send", color: .gray) }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(rows) { row in
                        GridRow {
                            HStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 2).fill(row.color).frame(width: 4, height: 14)
                                Text(row.label).font(.callout).lineLimit(1)
                                if row.sources.count == 2 { Text("stereo").font(.caption2).foregroundStyle(.secondary) }
                            }
                            .frame(minWidth: 150, alignment: .leading)
                            ForEach(groups) { g in
                                SendCell(gainDB: row.first.sends.first { $0.group == g.id }?.gainDB, range: -40...10, added: 0,
                                         help: "\(row.label) to \(g.name)") { v in set(row, group: g.id, gainDB: v) }
                                    .frame(width: cellWidth)
                            }
                            if hasLFE {
                                SendCell(gainDB: row.first.lfeDB, range: -40...10, added: -10, help: "\(row.label) to the LFE") { v in
                                    let values = v.map { db in SourceValues(lfeDB: db) } ?? SourceValues(lfeOff: true)
                                    model.apply(.updateSources(updates: row.sources.map { s in SourceUpdate(id: s.id, values: values) }))
                                }
                                .frame(width: cellWidth)
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    private func header(_ name: String, detail: String, color: Color) -> some View {
        VStack(spacing: 1) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(height: 3)
            Text(name).font(.caption.bold()).lineLimit(1)
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: cellWidth)
        .help(name)
    }

    /// Sets (or with nil removes) one send on every source in the row, keeping the groups' order.
    private func set(_ row: Row, group: UUID, gainDB: Double?) {
        model.apply(.updateSources(updates: row.sources.map { SourceUpdate(id: $0.id, values: SourceValues(sends: sends($0, group, gainDB))) }))
    }

    private func setAll(group: UUID, rows: [Row], gainDB: Double?) {
        let updates = rows.flatMap(\.sources).compactMap { s -> SourceUpdate? in
            // Adding at 0 dB leaves sends that already exist at their level.
            if gainDB != nil, s.sends.contains(where: { $0.group == group }) { return nil }
            if gainDB == nil, !s.sends.contains(where: { $0.group == group }) { return nil }
            return SourceUpdate(id: s.id, values: SourceValues(sends: sends(s, group, gainDB)))
        }
        if !updates.isEmpty { model.apply(.updateSources(updates: updates)) }
    }

    private func sends(_ s: Source, _ group: UUID, _ gainDB: Double?) -> [GroupSend] {
        var sends = s.sends.filter { $0.group != group }
        if let gainDB { sends.append(GroupSend(group: group, gainDB: gainDB)) }
        let order = state.show.groups.map(\.id)
        return sends.sorted { (order.firstIndex(of: $0.group) ?? 0) < (order.firstIndex(of: $1.group) ?? 0) }
    }
}

/// One cell: a level to drag when there is a send, a click target to add one when there is not.
private struct SendCell: View {
    let gainDB: Double?
    let range: ClosedRange<Double>
    let added: Double
    let help: String
    let set: (Double?) -> Void

    var body: some View {
        if let gainDB {
            DragValue(value: gainDB, range: range, step: 0.5, reset: 0,
                      text: { String(format: "%+.1f", $0) }, help: help) { set($0) }
                .contextMenu {
                    Button("0 dB") { set(0) }
                    Button("Remove send") { set(nil) }
                }
        } else {
            Text("·")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: 16)
                .background(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.08)))
                .contentShape(Rectangle())
                .onTapGesture { set(added) }
                .help("\(help): click to send at \(Int(added)) dB")
        }
    }
}

/// Window > Sends.
struct OpenSendsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Sends") { openWindow(id: "sends") }
            .keyboardShortcut("s", modifiers: [.command, .option])
    }
}
#endif

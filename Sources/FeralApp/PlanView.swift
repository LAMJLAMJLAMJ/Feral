#if canImport(SwiftUI) && os(macOS)
import FeralScene
import SwiftUI

/// Maps the venue's plan (x to stage right, y towards the audience, in metres) onto the view: stage
/// at the top, audience below, the same scale both ways.
struct PlanFrame {
    let minX: Double, minY: Double, scale: Double, offset: CGPoint

    init(bounds: (minX: Double, maxX: Double, minY: Double, maxY: Double), size: CGSize) {
        let w = max(bounds.maxX - bounds.minX, 1), h = max(bounds.maxY - bounds.minY, 1)
        let s = max(min(Double(size.width) / w, Double(size.height) / h), 1)
        minX = bounds.minX
        minY = bounds.minY
        scale = s
        offset = CGPoint(x: (Double(size.width) - w * s) / 2, y: (Double(size.height) - h * s) / 2)
    }

    func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: offset.x + (x - minX) * scale, y: offset.y + (y - minY) * scale)
    }

    func point(_ p: Position) -> CGPoint { point(p.x, p.y) }

    /// The venue x and y under a point in the view.
    func venue(_ p: CGPoint) -> (x: Double, y: Double) {
        ((Double(p.x) - offset.x) / scale + minX, (Double(p.y) - offset.y) / scale + minY)
    }

    /// The speakers and sources with 2 m around them, at least 12 m by 12 m.
    static func bounds(_ state: ShowState) -> (minX: Double, maxX: Double, minY: Double, maxY: Double) {
        let points = state.system.speakers.map(\.position) + state.show.sources.map(\.position) + [Position(0, 0, 0)]
        var minX = points.map(\.x).min()! - 2, maxX = points.map(\.x).max()! + 2
        var minY = points.map(\.y).min()! - 2, maxY = points.map(\.y).max()! + 2
        if maxX - minX < 12 { let c = (minX + maxX) / 2; minX = c - 6; maxX = c + 6 }
        if maxY - minY < 12 { let c = (minY + maxY) / 2; minY = c - 6; maxY = c + 6 }
        return (minX, maxX, minY, maxY)
    }
}

/// The plan: speakers coloured by group, sources as numbered dots. Drag a source to move it (the
/// engine renders it as it moves); with "Move speakers" on, speakers drag too.
struct PlanView: View {
    @ObservedObject var model: EngineModel
    let state: ShowState
    @Binding var selection: Selection?
    let moveSpeakers: Bool

    private struct Drag {
        var target: Selection
        var position: Position
    }
    @State private var drag: Drag?
    @State private var frozen: (minX: Double, maxX: Double, minY: Double, maxY: Double)?
    @State private var lastSent = Date.distantPast

    var body: some View {
        GeometryReader { geo in
            let frame = PlanFrame(bounds: frozen ?? PlanFrame.bounds(state), size: geo.size)
            Canvas { ctx, size in
                drawGrid(ctx, frame, size)
                drawSpeakers(ctx, frame)
                drawSources(ctx, frame)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in dragChanged(g, frame) }
                    .onEnded { g in dragEnded(g, frame) }
            )
            .overlay(alignment: .bottomLeading) {
                Text(hint).font(.caption).foregroundStyle(.secondary).padding(8)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var hint: String {
        if let drag, case .source = drag.target {
            return String(format: "x %.2f  y %.2f  z %.2f m", drag.position.x, drag.position.y, drag.position.z)
        }
        return "Drag a source to move it. Stage at the top, audience below; grid 1 m."
    }

    // MARK: Drawing

    private func drawGrid(_ ctx: GraphicsContext, _ f: PlanFrame, _ size: CGSize) {
        let lo = f.venue(.zero), hi = f.venue(CGPoint(x: size.width, y: size.height))
        var minor = Path(), major = Path()
        for x in Int(lo.x.rounded(.down))...Int(hi.x.rounded(.up)) {
            let a = f.point(Double(x), lo.y), b = f.point(Double(x), hi.y)
            if x % 5 == 0 { major.move(to: a); major.addLine(to: b) } else { minor.move(to: a); minor.addLine(to: b) }
        }
        for y in Int(lo.y.rounded(.down))...Int(hi.y.rounded(.up)) {
            let a = f.point(lo.x, Double(y)), b = f.point(hi.x, Double(y))
            if y % 5 == 0 { major.move(to: a); major.addLine(to: b) } else { minor.move(to: a); minor.addLine(to: b) }
        }
        ctx.stroke(minor, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)
        ctx.stroke(major, with: .color(.secondary.opacity(0.3)), lineWidth: 0.8)
        var axes = Path()
        axes.move(to: f.point(lo.x, 0)); axes.addLine(to: f.point(hi.x, 0))
        axes.move(to: f.point(0, lo.y)); axes.addLine(to: f.point(0, hi.y))
        ctx.stroke(axes, with: .color(.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        ctx.draw(Text("STAGE").font(.caption2.bold()).foregroundColor(.secondary), at: CGPoint(x: size.width / 2, y: 12))
        ctx.draw(Text("AUDIENCE").font(.caption2.bold()).foregroundColor(.secondary), at: CGPoint(x: size.width / 2, y: size.height - 12))
    }

    private func drawSpeakers(_ ctx: GraphicsContext, _ f: PlanFrame) {
        var groupOf: [UUID: SpeakerGroup] = [:]
        for g in state.show.groups { for s in g.speakers where groupOf[s] == nil { groupOf[s] = g } }
        for sp in state.system.speakers {
            var position = sp.position
            if let drag, drag.target == .speaker(sp.id) { position = drag.position }
            let c = f.point(position)
            let colour = groupOf[sp.id]?.color ?? .gray
            let r: CGFloat = 6
            var box = Path()
            box.move(to: CGPoint(x: c.x, y: c.y - r)); box.addLine(to: CGPoint(x: c.x + r, y: c.y))
            box.addLine(to: CGPoint(x: c.x, y: c.y + r)); box.addLine(to: CGPoint(x: c.x - r, y: c.y)); box.closeSubpath()
            ctx.fill(box, with: .color(colour.opacity(sp.mute ? 0.25 : 0.8)))
            if selection == .speaker(sp.id) {
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20)), with: .color(.accentColor), lineWidth: 2)
            }
            ctx.draw(Text("\(sp.number)").font(.system(size: 9)).foregroundColor(.secondary),
                     at: CGPoint(x: c.x, y: c.y + r + 7))
        }
    }

    private func drawSources(_ ctx: GraphicsContext, _ f: PlanFrame) {
        let fading = Set(model.status?.fading ?? [])
        for s in state.show.sources {
            var position = s.position
            if let drag, drag.target == .source(s.id) { position = drag.position }
            let c = f.point(position)
            let r: CGFloat = 10
            let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            if s.mute {
                ctx.stroke(circle, with: .color(s.color), lineWidth: 2)
            } else {
                ctx.fill(circle, with: .color(s.color))
            }
            if fading.contains(s.id) {
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r - 4, y: c.y - r - 4, width: 2 * r + 8, height: 2 * r + 8)),
                           with: .color(s.color), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
            if selection == .source(s.id) {
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r - 3, y: c.y - r - 3, width: 2 * r + 6, height: 2 * r + 6)),
                           with: .color(.accentColor), lineWidth: 2)
            }
            ctx.draw(Text("\(s.number)").font(.system(size: 10, weight: .bold)).foregroundColor(s.mute ? s.color : .white), at: c)
            if let name = s.name {
                ctx.draw(Text(name).font(.caption), at: CGPoint(x: c.x + r + 4, y: c.y), anchor: .leading)
            }
        }
    }

    // MARK: Dragging

    private func hit(_ p: CGPoint, _ f: PlanFrame) -> Selection? {
        func distance(_ q: Position) -> CGFloat { hypot(f.point(q).x - p.x, f.point(q).y - p.y) }
        if let s = state.show.sources.min(by: { distance($0.position) < distance($1.position) }), distance(s.position) <= 14 {
            return .source(s.id)
        }
        if let s = state.system.speakers.min(by: { distance($0.position) < distance($1.position) }), distance(s.position) <= 10 {
            return .speaker(s.id)
        }
        return nil
    }

    private func dragChanged(_ g: DragGesture.Value, _ f: PlanFrame) {
        if drag == nil {
            guard let target = hit(g.startLocation, f) else { return }
            selection = target
            switch target {
            case .source(let id):
                guard let s = state.source(id) else { return }
                drag = Drag(target: target, position: s.position)
            case .speaker(let id):
                guard moveSpeakers, let s = state.speaker(id) else { return }
                drag = Drag(target: target, position: s.position)
            default:
                return
            }
            frozen = PlanFrame.bounds(state)
        }
        guard var d = drag else { return }
        let v = f.venue(g.location)
        // Snap to 10 cm.
        d.position = Position((v.x * 10).rounded() / 10, (v.y * 10).rounded() / 10, d.position.z)
        drag = d
        if Date().timeIntervalSince(lastSent) >= 1.0 / 60 { send(d) }
    }

    private func dragEnded(_ g: DragGesture.Value, _ f: PlanFrame) {
        if let d = drag {
            send(d)
        } else if hit(g.startLocation, f) == nil {
            selection = nil
        }
        drag = nil
        frozen = nil
    }

    private func send(_ d: Drag) {
        lastSent = Date()
        switch d.target {
        case .source(let id):
            model.update(id, SourceValues(position: d.position))
        case .speaker(let id):
            guard var s = state.speaker(id) else { return }
            s.position = d.position
            model.apply(.setSpeaker(speaker: s))
        default:
            break
        }
    }
}
#endif

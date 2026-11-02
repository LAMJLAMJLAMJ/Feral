#if canImport(SwiftUI) && os(macOS)
import FeralScene
import SwiftUI

/// The height panel to the right of the plan: the venue seen from the front (left to right as on the plan) or
/// from the side (stage on the left, audience on the right), with height going up. Drag a source up
/// or down to set its height; with the lock open it also moves across. With "Move speakers" on, speakers drag too.
struct ElevationView: View {
    @ObservedObject var model: EngineModel
    @ObservedObject var meters: MeterStore
    let state: ShowState
    @Binding var selection: Selection?
    let moveSpeakers: Bool
    /// Unhidden; when hidden only the title bar stays, to unhide it from.
    @Binding var shown: Bool
    @AppStorage("elevationSide") private var side = false
    /// The panel's width, set by dragging its left edge.
    @AppStorage("elevationWidth") private var width: Double = 280
    /// Locked: dragging changes only the height. Unlocked: it also moves across (left/right from the
    /// front, stage/audience from the side).
    @AppStorage("elevationLockAcross") private var lockAcross = true
    @State private var resizeStart: Double?

    private struct Drag {
        var target: Selection
        var position: Position
        /// Where the source started, and where its linked group partners started.
        var start: Position
        var partners: [UUID: Position] = [:]
    }
    @State private var drag: Drag?
    @State private var frozen: Frame?
    @State private var lastSent = Date.distantPast

    /// Across (x from the front, y from the side) and height (z) onto the view, same scale both ways.
    struct Frame {
        let minA: Double, minZ: Double, maxZ: Double, scale: Double, offset: CGPoint, height: Double

        init(minA: Double, maxA: Double, minZ: Double, maxZ: Double, size: CGSize) {
            let w = max(maxA - minA, 1), h = max(maxZ - minZ, 1)
            let s = max(min(Double(size.width) / w, Double(size.height) / h), 1)
            self.minA = minA; self.minZ = minZ; self.maxZ = maxZ; scale = s; height = Double(size.height)
            offset = CGPoint(x: (Double(size.width) - w * s) / 2, y: (Double(size.height) - h * s) / 2)
        }

        func point(_ a: Double, _ z: Double) -> CGPoint {
            CGPoint(x: offset.x + (a - minA) * scale, y: height - offset.y - (z - minZ) * scale)
        }

        func z(at y: CGFloat) -> Double { (height - offset.y - Double(y)) / scale + minZ }

        func across(at x: CGFloat) -> Double { (Double(x) - offset.x) / scale + minA }
    }

    /// Where a position sits across the view.
    private func across(_ p: Position) -> Double { side ? p.y : p.x }

    private func frame(_ size: CGSize) -> Frame {
        let points = state.system.speakers.map(\.position) + state.show.sources.map(\.position)
            + [Position(0, 0, 0), state.system.listener.position]
        var lo = points.map(across).min()! - 2, hi = points.map(across).max()! + 2
        if hi - lo < 12 { let c = (lo + hi) / 2; lo = c - 6; hi = c + 6 }
        let top = max(points.map(\.z).max()! + 2, 6)
        let bottom = min(points.map(\.z).min()! - 1, -1)
        return Frame(minA: lo, maxA: hi, minZ: bottom, maxZ: top, size: size)
    }

    static let minWidth: Double = 200, maxWidth: Double = 900

    var body: some View {
        if shown {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button { withAnimation(.easeInOut(duration: 0.15)) { shown = false } } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right").font(.caption2.bold())
                            Text("HEIGHT").font(.caption2.bold())
                        }
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Hide the height view (⇧⌘E)")
                    Spacer()
                    Button { lockAcross.toggle() } label: {
                        Image(systemName: lockAcross ? "lock.fill" : "lock.open")
                            .foregroundStyle(lockAcross ? Color.secondary : Color.accentColor)
                            .frame(width: 18)
                    }
                    .buttonStyle(.borderless)
                    .help(lockAcross ? lockedHelp : unlockedHelp)
                    Picker("View", selection: $side) {
                        Text("Front").tag(false)
                        Text("Side").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 110)
                    .help("Front: left to right as on the plan. Side: stage on the left, audience on the right.")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.bar)
                GeometryReader { geo in
                    let f = frozen ?? frame(geo.size)
                    Canvas { ctx, size in
                        drawGrid(ctx, f, size)
                        drawSpeakers(ctx, f)
                        drawListener(ctx, f)
                        drawSources(ctx, f)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in dragChanged(g, f) }
                            .onEnded { g in dragEnded(g, f) }
                    )
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipped()
                Text(hint).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(6)
                    .background(.bar)
            }
            .frame(width: CGFloat(min(max(width, Self.minWidth), Self.maxWidth)))
            .overlay(alignment: .leading) { resizeHandle }
        } else {
            // Hidden: a thin strip to show it again from.
            Button { withAnimation(.easeInOut(duration: 0.15)) { shown = true } } label: {
                VStack(spacing: 8) {
                    Image(systemName: "chevron.left").font(.caption2.bold())
                    Text("HEIGHT").font(.caption2.bold()).fixedSize().rotationEffect(.degrees(90)).frame(width: 14, height: 50)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .frame(width: 22)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(.bar)
            .help("Show the height view (⇧⌘E)")
        }
    }

    private var lockedHelp: String {
        "Locked: dragging changes only the height. Click to also move " + (side ? "front to back." : "left and right.")
    }

    private var unlockedHelp: String {
        "Unlocked: dragging also moves " + (side ? "front to back" : "left and right") + ". Click to lock to height only."
    }

    /// The left edge: drag it to make the panel wider or narrower.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { g in
                        let start = resizeStart ?? min(max(width, Self.minWidth), Self.maxWidth)
                        resizeStart = start
                        width = min(max(start - Double(g.translation.width), Self.minWidth), Self.maxWidth)
                    }
                    .onEnded { _ in resizeStart = nil }
            )
            .help("Drag to resize the height view")
    }

    private var hint: String {
        if let drag {
            let p = drag.position
            if lockAcross { return String(format: "height %.1f m", p.z) }
            return String(format: "%@ %.1f m, height %.1f m", side ? "y" : "x", across(p), p.z)
        }
        return lockAcross ? "Drag a source up or down to set its height"
            : "Drag a source to move it " + (side ? "front to back" : "left and right") + " and up or down"
    }

    // MARK: Drawing

    private func drawGrid(_ ctx: GraphicsContext, _ f: Frame, _ size: CGSize) {
        let loA = (0 - f.offset.x) / f.scale + f.minA, hiA = (Double(size.width) - f.offset.x) / f.scale + f.minA
        var minor = Path(), major = Path()
        for a in Int(loA.rounded(.down))...Int(hiA.rounded(.up)) {
            let p0 = f.point(Double(a), f.minZ), p1 = f.point(Double(a), f.maxZ)
            if a % 5 == 0 { major.move(to: p0); major.addLine(to: p1) } else { minor.move(to: p0); minor.addLine(to: p1) }
        }
        for z in Int(f.minZ.rounded(.down))...Int(f.maxZ.rounded(.up)) {
            let p0 = f.point(loA, Double(z)), p1 = f.point(hiA, Double(z))
            if z % 5 == 0 { major.move(to: p0); major.addLine(to: p1) } else { minor.move(to: p0); minor.addLine(to: p1) }
            if z > 0 {
                ctx.draw(Text("\(z) m").font(.system(size: 8)).foregroundColor(.secondary),
                         at: CGPoint(x: 4, y: f.point(0, Double(z)).y), anchor: .leading)
            }
        }
        ctx.stroke(minor, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)
        ctx.stroke(major, with: .color(.secondary.opacity(0.3)), lineWidth: 0.8)
        // The floor, z = 0.
        var floor = Path()
        floor.move(to: f.point(loA, 0)); floor.addLine(to: f.point(hiA, 0))
        ctx.stroke(floor, with: .color(.secondary.opacity(0.8)), lineWidth: 1.5)
        if side {
            ctx.draw(Text("STAGE").font(.caption2.bold()).foregroundColor(.secondary), at: CGPoint(x: 6, y: size.height - 8), anchor: .leading)
            ctx.draw(Text("AUDIENCE").font(.caption2.bold()).foregroundColor(.secondary), at: CGPoint(x: size.width - 6, y: size.height - 8), anchor: .trailing)
        } else {
            ctx.draw(Text("FRONT VIEW").font(.caption2.bold()).foregroundColor(.secondary), at: CGPoint(x: size.width / 2, y: size.height - 8))
        }
    }

    private func drawSpeakers(_ ctx: GraphicsContext, _ f: Frame) {
        let groups = groupOf(state)
        for sp in state.system.speakers {
            var p = sp.position
            if let drag, drag.target == .speaker(sp.id) { p = drag.position }
            let c = f.point(across(p), p.z)
            let r: CGFloat = 5
            var box = Path()
            box.move(to: CGPoint(x: c.x, y: c.y - r)); box.addLine(to: CGPoint(x: c.x + r, y: c.y))
            box.addLine(to: CGPoint(x: c.x, y: c.y + r)); box.addLine(to: CGPoint(x: c.x - r, y: c.y)); box.closeSubpath()
            ctx.fill(box, with: .color((groups[sp.id]?.color ?? .gray).opacity(sp.mute ? 0.25 : 0.8)))
            if selection == .speaker(sp.id) {
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)), with: .color(.accentColor), lineWidth: 2)
            }
        }
    }

    /// The listener as a ring at its height.
    private func drawListener(_ ctx: GraphicsContext, _ f: Frame) {
        let p = state.system.listener.position
        let c = f.point(across(p), p.z)
        let colour = Color.primary.opacity(0.7)
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: .color(colour), lineWidth: 2)
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: .color(colour))
        if selection == .listener {
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20)), with: .color(.accentColor), lineWidth: 2)
        }
    }

    private func drawSources(_ ctx: GraphicsContext, _ f: Frame) {
        for s in state.show.sources {
            var p = s.position
            if let drag, drag.target == .source(s.id) { p = drag.position }
            let c = f.point(across(p), p.z)
            let r: CGFloat = 8
            // A stalk from the floor shows the height at a glance.
            var stalk = Path()
            stalk.move(to: f.point(across(p), 0)); stalk.addLine(to: c)
            ctx.stroke(stalk, with: .color(s.color.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            if s.mute { ctx.stroke(circle, with: .color(s.color), lineWidth: 2) } else { ctx.fill(circle, with: .color(s.color)) }
            if selection == .source(s.id) {
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r - 3, y: c.y - r - 3, width: 2 * r + 6, height: 2 * r + 6)),
                           with: .color(.accentColor), lineWidth: 2)
            }
            ctx.draw(Text("\(s.number)").font(.system(size: 9, weight: .bold)).foregroundColor(s.mute ? s.color : Color.white), at: c)
            ctx.draw(Text(String(format: "%.1f m", p.z)).font(.system(size: 8)).foregroundColor(.secondary),
                     at: CGPoint(x: c.x + r + 3, y: c.y), anchor: .leading)
        }
    }

    // MARK: Dragging

    private func hit(_ point: CGPoint, _ f: Frame) -> Selection? {
        func distance(_ p: Position) -> CGFloat {
            let c = f.point(across(p), p.z)
            return hypot(c.x - point.x, c.y - point.y)
        }
        if let s = state.show.sources.min(by: { distance($0.position) < distance($1.position) }), distance(s.position) <= 12 {
            return .source(s.id)
        }
        if let s = state.system.speakers.min(by: { distance($0.position) < distance($1.position) }), distance(s.position) <= 9 {
            return .speaker(s.id)
        }
        return nil
    }

    private func dragChanged(_ g: DragGesture.Value, _ f: Frame) {
        if drag == nil {
            guard let target = hit(g.startLocation, f) else { return }
            selection = target
            switch target {
            case .source(let id):
                guard let s = state.source(id) else { return }
                drag = Drag(target: target, position: s.position, start: s.position, partners: model.dragPartners(of: id))
            case .speaker(let id):
                guard moveSpeakers, let s = state.speaker(id) else { return }
                drag = Drag(target: target, position: s.position, start: s.position)
            default:
                return
            }
            frozen = f
        }
        guard var d = drag else { return }
        // Only the height changes; snap to 10 cm, from 2 m below the floor to 50 m up.
        let z = min(max((f.z(at: g.location.y) * 10).rounded() / 10, -2), 50)
        var x = d.position.x, y = d.position.y
        if !lockAcross {
            let a = (f.across(at: g.location.x) * 10).rounded() / 10
            if side { y = a } else { x = a }
        }
        d.position = Position(x, y, z)
        drag = d
        if Date().timeIntervalSince(lastSent) >= 1.0 / 60 { send(d) }
    }

    private func dragEnded(_ g: DragGesture.Value, _ f: Frame) {
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
            model.drag(id, from: d.start, to: d.position, partners: d.partners)
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

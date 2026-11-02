#if canImport(SwiftUI) && os(macOS)
import FeralScene
import SwiftUI

/// Maps the venue's plan (x to stage right, y towards the audience, in metres) onto the view: stage
/// at the top, audience below, the same scale both ways. `zoom` 1 fits the show; `pan` moves the view
/// in points.
struct PlanFrame {
    let minX: Double, minY: Double, scale: Double, offset: CGPoint

    init(bounds: (minX: Double, maxX: Double, minY: Double, maxY: Double), size: CGSize, zoom: Double = 1,
         pan: CGSize = .zero) {
        let w = max(bounds.maxX - bounds.minX, 1), h = max(bounds.maxY - bounds.minY, 1)
        let s = max(min(Double(size.width) / w, Double(size.height) / h), 1) * zoom
        minX = bounds.minX
        minY = bounds.minY
        scale = s
        offset = CGPoint(x: (Double(size.width) - w * s) / 2 + pan.width, y: (Double(size.height) - h * s) / 2 + pan.height)
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
        let points = state.system.speakers.map(\.position) + state.show.sources.map(\.position)
            + [Position(0, 0, 0), state.system.listener.position]
        var minX = points.map(\.x).min()! - 2, maxX = points.map(\.x).max()! + 2
        var minY = points.map(\.y).min()! - 2, maxY = points.map(\.y).max()! + 2
        if maxX - minX < 12 { let c = (minX + maxX) / 2; minX = c - 6; maxX = c + 6 }
        if maxY - minY < 12 { let c = (minY + maxY) / 2; minY = c - 6; maxY = c + 6 }
        return (minX, maxX, minY, maxY)
    }
}

/// The plan: speakers coloured by group, sources as numbered dots, both lit by their level. Drag a
/// source to move it (the engine renders it as it moves); with "Move speakers" on, speakers drag too.
/// Drag empty space to pan, pinch to zoom.
struct PlanView: View {
    @ObservedObject var model: EngineModel
    @ObservedObject var meters: MeterStore
    let state: ShowState
    @Binding var selection: Selection?
    let moveSpeakers: Bool
    @AppStorage("planLevels") private var showLevels = true
    @AppStorage("planSpeakerNames") private var speakerNames = false

    private struct Drag {
        var target: Selection
        var position: Position
        /// Where the source started, and where its linked group partners started.
        var start: Position
        var partners: [UUID: Position] = [:]
    }
    @State private var drag: Drag?
    @State private var panning: (start: CGSize, moved: Bool)?
    @State private var frozen: (minX: Double, maxX: Double, minY: Double, maxY: Double)?
    @State private var lastSent = Date.distantPast
    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @State private var pinchStart: Double?

    var body: some View {
        GeometryReader { geo in
            let frame = PlanFrame(bounds: frozen ?? PlanFrame.bounds(state), size: geo.size, zoom: zoom, pan: pan)
            Canvas { ctx, size in
                drawGrid(ctx, frame, size)
                drawSpeakers(ctx, frame)
                drawListener(ctx, frame)
                drawSources(ctx, frame)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in dragChanged(g, frame) }
                    .onEnded { g in dragEnded(g, frame) }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { g in
                        if pinchStart == nil { pinchStart = zoom }
                        setZoom((pinchStart ?? 1) * Double(g.magnification))
                    }
                    .onEnded { _ in pinchStart = nil }
            )
            .overlay(alignment: .topLeading) { legend.padding(8) }
            .overlay(alignment: .topTrailing) { controls.padding(8) }
            .overlay(alignment: .bottomLeading) {
                Text(hint).font(.caption).foregroundStyle(.secondary).padding(8)
            }
            .overlay(alignment: .bottomTrailing) { scaleBar(frame).padding(10) }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipped()
    }

    private var hint: String {
        if let drag {
            return String(format: "x %.2f  y %.2f  z %.2f m", drag.position.x, drag.position.y, drag.position.z)
        }
        return "Drag a source to move it · drag empty space to pan, pinch to zoom · stage at the top"
    }

    // MARK: Overlays

    private var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(state.show.groups) { g in
                HStack(spacing: 5) {
                    Image(systemName: "diamond.fill").foregroundStyle(g.color).font(.system(size: 9))
                    Text(g.name).font(.caption)
                    Text(g.renderer.rawValue).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if state.show.groups.isEmpty {
                Text("No speaker groups: fixed routing").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private var controls: some View {
        HStack(spacing: 2) {
            Button { setZoom(zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Button { zoom = 1; pan = .zero } label: { Text("Fit").font(.caption) }
                .help("Fit the whole show")
            Button { setZoom(zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
            Divider().frame(height: 14)
            Toggle(isOn: $showLevels) { Image(systemName: "waveform") }
                .toggleStyle(.button)
                .help("Light sources and speakers by their level")
            Toggle(isOn: $speakerNames) { Image(systemName: "textformat") }
                .toggleStyle(.button)
                .help("Show speaker names")
        }
        .buttonStyle(.borderless)
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private func setZoom(_ z: Double) {
        let new = max(0.5, min(z, 12))
        // Keep what is in the middle of the view in the middle.
        pan = CGSize(width: pan.width * new / zoom, height: pan.height * new / zoom)
        zoom = new
    }

    /// A bar of a round number of metres, about 80 points long.
    private func scaleBar(_ f: PlanFrame) -> some View {
        let metres = [0.5, 1, 2, 5, 10, 20, 50].first { $0 * f.scale >= 60 } ?? 50
        return VStack(alignment: .trailing, spacing: 2) {
            Text(metres < 1 ? "50 cm" : "\(Int(metres)) m").font(.caption2).foregroundStyle(.secondary)
            Rectangle().fill(Color.secondary).frame(width: metres * f.scale, height: 2)
        }
    }

    // MARK: Drawing

    private func drawGrid(_ ctx: GraphicsContext, _ f: PlanFrame, _ size: CGSize) {
        let lo = f.venue(.zero), hi = f.venue(CGPoint(x: size.width, y: size.height))
        var minor = Path(), major = Path()
        // Fine lines every metre unless they would crowd, then every 5 m.
        let step = f.scale >= 8 ? 1 : 5
        for x in stride(from: Int(lo.x.rounded(.down)), through: Int(hi.x.rounded(.up)), by: 1) where x % step == 0 {
            let a = f.point(Double(x), lo.y), b = f.point(Double(x), hi.y)
            if x % 5 == 0 { major.move(to: a); major.addLine(to: b) } else { minor.move(to: a); minor.addLine(to: b) }
        }
        for y in stride(from: Int(lo.y.rounded(.down)), through: Int(hi.y.rounded(.up)), by: 1) where y % step == 0 {
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

    /// 0 for silence (-60 dBFS and below) to 1 at full scale.
    private func glow(_ c: MeterStore.Channel?) -> CGFloat {
        guard showLevels, let c else { return 0 }
        return MeterScale.fraction(max(c.rms, c.peak - 12))
    }

    private func drawSpeakers(_ ctx: GraphicsContext, _ f: PlanFrame) {
        let groups = groupOf(state)
        for sp in state.system.speakers {
            var position = sp.position
            if let drag, drag.target == .speaker(sp.id) { position = drag.position }
            let c = f.point(position)
            let colour = groups[sp.id]?.color ?? .gray
            let r: CGFloat = 6
            let level = glow(meters.output(sp.output))
            if level > 0.02 {
                let g = r + 3 + level * 12
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - g, y: c.y - g, width: 2 * g, height: 2 * g)),
                         with: .color(colour.opacity(0.12 + 0.3 * level)))
            }
            var box = Path()
            box.move(to: CGPoint(x: c.x, y: c.y - r)); box.addLine(to: CGPoint(x: c.x + r, y: c.y))
            box.addLine(to: CGPoint(x: c.x, y: c.y + r)); box.addLine(to: CGPoint(x: c.x - r, y: c.y)); box.closeSubpath()
            ctx.fill(box, with: .color(colour.opacity(sp.mute ? 0.25 : 0.85)))
            if meters.output(sp.output)?.clipped == true {
                ctx.stroke(box, with: .color(.red), lineWidth: 1.5)
            }
            if selection == .speaker(sp.id) {
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20)), with: .color(.accentColor), lineWidth: 2)
            }
            let label = speakerNames ? sp.label : "\(sp.number)"
            ctx.draw(Text(label).font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: c.x, y: c.y + r + 7))
        }
    }

    /// The listening point that azimuth, elevation and distance are measured from: a head with a
    /// nose pointing the way it faces.
    private func drawListener(_ ctx: GraphicsContext, _ f: PlanFrame) {
        let l = state.system.listener
        var at = l.position
        if let drag, drag.target == .listener { at = drag.position }
        let c = f.point(at)
        let a = l.facing * Double.pi / 180
        let ahead = f.point(Position(at.x - sin(a), at.y + cos(a), at.z))
        let len = max(hypot(ahead.x - c.x, ahead.y - c.y), 0.001)
        let dir = CGPoint(x: (ahead.x - c.x) / len, y: (ahead.y - c.y) / len)
        let r: CGFloat = 8
        var nose = Path()
        nose.move(to: CGPoint(x: c.x + dir.x * (r + 7), y: c.y + dir.y * (r + 7)))
        nose.addLine(to: CGPoint(x: c.x - dir.y * 5 + dir.x * (r - 2), y: c.y + dir.x * 5 + dir.y * (r - 2)))
        nose.addLine(to: CGPoint(x: c.x + dir.y * 5 + dir.x * (r - 2), y: c.y - dir.x * 5 + dir.y * (r - 2)))
        nose.closeSubpath()
        let colour = Color.primary.opacity(0.75)
        ctx.fill(nose, with: .color(colour))
        let head = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.stroke(head, with: .color(colour), lineWidth: 2)
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: .color(colour))
        if selection == .listener {
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r - 4, y: c.y - r - 4, width: 2 * r + 8, height: 2 * r + 8)),
                       with: .color(.accentColor), lineWidth: 2)
        }
        ctx.draw(Text("LISTENER").font(.system(size: 8, weight: .semibold)).foregroundColor(.secondary),
                 at: CGPoint(x: c.x, y: c.y + r + 9))
    }

    private func drawSources(_ ctx: GraphicsContext, _ f: PlanFrame) {
        let fading = Set(model.status?.fading ?? [])
        // Stereo pairs: a line from left to right, dashed while unpaired.
        for g in state.show.sourceGroups where g.stereo {
            guard let pair = state.stereoPair(g) else { continue }
            var line = Path()
            line.move(to: f.point(pair.left.position))
            line.addLine(to: f.point(pair.right.position))
            ctx.stroke(line, with: .color(g.color.opacity(0.7)),
                       style: StrokeStyle(lineWidth: 2, dash: g.linked ? [] : [4, 3]))
        }
        for s in state.show.sources {
            var position = s.position
            if let drag, drag.target == .source(s.id) { position = drag.position }
            let c = f.point(position)
            let r: CGFloat = 10
            let level = glow(meters.input(s.input))
            if level > 0.02 && !s.mute {
                let g = r + 2 + level * 10
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - g, y: c.y - g, width: 2 * g, height: 2 * g)),
                           with: .color(s.color.opacity(0.25 + 0.5 * level)), lineWidth: 1 + 3 * level)
            }
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
            let owner = model.status?.owner(of: s.id) ?? .cues
            if owner != .cues {
                // Live from QLab or tracking: an orange ring, and cues leave its position alone.
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r - 1.5, y: c.y - r - 1.5, width: 2 * r + 3, height: 2 * r + 3)),
                           with: .color(.orange), lineWidth: 2)
            }
            if selection == .source(s.id) {
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r - 4, y: c.y - r - 4, width: 2 * r + 8, height: 2 * r + 8)),
                           with: .color(.accentColor), lineWidth: 2)
            }
            ctx.draw(Text("\(s.number)").font(.system(size: 10, weight: .bold)).foregroundColor(s.mute ? s.color : .white), at: c)
            var caption = s.name ?? ""
            if owner != .cues {
                let who = owner == .osc ? "OSC" : owner.label
                caption += caption.isEmpty ? who : " · \(who)"
            }
            if !caption.isEmpty {
                ctx.draw(Text(caption).font(.caption).foregroundColor(owner == .cues ? Color.primary : Color.orange),
                         at: CGPoint(x: c.x + r + 5, y: c.y), anchor: .leading)
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
        if distance(state.system.listener.position) <= 12 { return .listener }
        return nil
    }

    private func dragChanged(_ g: DragGesture.Value, _ f: PlanFrame) {
        if drag == nil && panning == nil {
            if let target = hit(g.startLocation, f) {
                selection = target
                switch target {
                case .source(let id):
                    guard let s = state.source(id) else { return }
                    drag = Drag(target: target, position: s.position, start: s.position, partners: model.dragPartners(of: id))
                case .speaker(let id):
                    guard moveSpeakers, let s = state.speaker(id) else { return }
                    drag = Drag(target: target, position: s.position, start: s.position)
                case .listener:
                    guard moveSpeakers else { return }
                    let p = state.system.listener.position
                    drag = Drag(target: target, position: p, start: p)
                default:
                    return
                }
                frozen = PlanFrame.bounds(state)
            } else {
                panning = (pan, false)
            }
        }
        if let p = panning {
            let moved = p.moved || hypot(g.translation.width, g.translation.height) > 3
            panning = (p.start, moved)
            if moved { pan = CGSize(width: p.start.width + g.translation.width, height: p.start.height + g.translation.height) }
            return
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
        } else if let p = panning, !p.moved {
            // A click on empty space.
            selection = nil
        }
        drag = nil
        panning = nil
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
        case .listener:
            var l = state.system.listener
            l.position = d.position
            model.apply(.setListener(listener: l))
        default:
            break
        }
    }
}
#endif

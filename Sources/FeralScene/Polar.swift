import Foundation

/// Positions as azimuth, elevation and distance, with the same convention as ADM-OSC: azimuth 0 is
/// straight ahead, positive to the left, from -180 to 180; elevation 0 is level, 90 straight up;
/// distance in metres. Position.polar is from the venue's origin facing +y; ShowState.polar(of:) is
/// from the show's listener, facing its way.
public struct Polar: Equatable {
    public var azimuth: Double
    public var elevation: Double
    public var distance: Double

    public init(azimuth: Double, elevation: Double, distance: Double) {
        self.azimuth = azimuth; self.elevation = elevation; self.distance = distance
    }
}

extension Position {
    public var polar: Polar {
        let p = ADMBox.polar(x: x, y: y, z: z)
        return Polar(azimuth: p.azimuth, elevation: p.elevation, distance: p.distance)
    }

    public init(_ p: Polar) {
        let c = ADMBox.cartesian(azimuth: p.azimuth, elevation: p.elevation, distance: p.distance)
        self.init(c.x, c.y, c.z)
    }

    /// Rounded to the millimetre, so round trips through polar do not leave 1e-15 crumbs.
    var tidy: Position {
        func r(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        return Position(r(x), r(y), r(z))
    }
}

extension Listener {
    /// A position as seen from the listener.
    public func polar(of p: Position) -> Polar {
        var v = Position(p.x - position.x, p.y - position.y, p.z - position.z).polar
        if v.distance > 0 { v.azimuth = ShowState.wrap(v.azimuth - facing) }
        return v
    }

    /// The position at a direction and distance from the listener.
    public func point(_ v: Polar) -> Position {
        let d = Position(Polar(azimuth: v.azimuth + facing, elevation: v.elevation, distance: v.distance))
        return Position(position.x + d.x, position.y + d.y, position.z + d.z).tidy
    }
}

extension ShowState {
    /// A position's azimuth, elevation and distance from the show's listener.
    public func polar(of p: Position) -> Polar { system.listener.polar(of: p) }

    /// The position at an azimuth, elevation and distance from the show's listener.
    public func point(_ v: Polar) -> Position { system.listener.point(v) }

    /// A source group's centre: the average of its members' positions.
    public func centre(of group: SourceGroup) -> Position? {
        let members = group.sources.compactMap { source($0)?.position }
        guard !members.isEmpty else { return nil }
        let n = Double(members.count)
        return Position(members.map(\.x).reduce(0, +) / n, members.map(\.y).reduce(0, +) / n, members.map(\.z).reduce(0, +) / n)
    }

    /// Moves a group's centre to a new azimuth, elevation or distance from the listener (each
    /// optional), keeping its shape: a new azimuth turns every member round the listener by the same angle, a new elevation
    /// raises every member by the same angle, a new distance scales every member's distance by the
    /// same factor.
    public func moveGroup(_ group: SourceGroup, azimuth: Double? = nil, elevation: Double? = nil,
                          distance: Double? = nil) -> [SourceUpdate] {
        guard let centre = centre(of: group) else { return [] }
        let c = polar(of: centre)
        let turn = azimuth.map { $0 - c.azimuth } ?? 0
        let raise = elevation.map { $0 - c.elevation } ?? 0
        let scale = distance.map { c.distance > 0 ? max($0, 0) / c.distance : 1 } ?? 1
        return group.sources.compactMap { id -> SourceUpdate? in
            guard let s = source(id) else { return nil }
            var p = polar(of: s.position)
            if p.distance == 0 && distance != nil && c.distance == 0 {
                // Everything on the listener: push it out straight ahead.
                p = Polar(azimuth: 0, elevation: 0, distance: max(distance ?? 0, 0))
            }
            p.azimuth = Self.wrap(p.azimuth + turn)
            p.elevation = min(max(p.elevation + raise, -90), 90)
            p.distance *= scale
            return SourceUpdate(id: id, values: SourceValues(position: point(p)))
        }
    }

    // MARK: Stereo pairs

    /// A stereo pair's left and right sources (its first two members).
    public func stereoPair(_ group: SourceGroup) -> (left: Source, right: Source)? {
        guard group.stereo, group.sources.count >= 2, let l = source(group.sources[0]), let r = source(group.sources[1]) else { return nil }
        return (l, r)
    }

    /// The azimuth between a stereo pair's left and right, seen from the listener: 0 when they are on
    /// top of each other, positive while left is to the left of right.
    public func spacing(of group: SourceGroup) -> Double? {
        guard let pair = stereoPair(group) else { return nil }
        return Self.wrap(polar(of: pair.left.position).azimuth - polar(of: pair.right.position).azimuth)
    }

    /// Spreads a stereo pair to a new spacing, symmetrically round the azimuth halfway between them;
    /// each side keeps its own elevation and distance.
    public func setSpacing(_ group: SourceGroup, to degrees: Double) -> [SourceUpdate] {
        guard let pair = stereoPair(group), let now = spacing(of: group) else { return [] }
        let l = pair.left, r = pair.right
        let pl = polar(of: l.position), pr = polar(of: r.position)
        let middle = Self.wrap(pr.azimuth + now / 2)
        let half = min(max(degrees, 0), 360) / 2
        var nl = pl, nr = pr
        nl.azimuth = Self.wrap(middle + half)
        nr.azimuth = Self.wrap(middle - half)
        if pl.distance == 0 { nl.distance = max(pr.distance, 1) }
        if pr.distance == 0 { nr.distance = max(pl.distance, 1) }
        return [SourceUpdate(id: l.id, values: SourceValues(position: point(nl))),
                SourceUpdate(id: r.id, values: SourceValues(position: point(nr)))]
    }

    /// Moves a linked group's other members by the same amount as one member, which moves from
    /// `from` to `to`. Gives the update for every member, the moved one included.
    public func moveTogether(_ id: UUID, from: Position, to: Position, starts: [UUID: Position]) -> [SourceUpdate] {
        let dx = to.x - from.x, dy = to.y - from.y, dz = to.z - from.z
        var updates = [SourceUpdate(id: id, values: SourceValues(position: to))]
        for (other, start) in starts where other != id && source(other) != nil {
            let p = Position(start.x + dx, start.y + dy, start.z + dz).tidy
            updates.append(SourceUpdate(id: other, values: SourceValues(position: p)))
        }
        return updates
    }

    /// The sources that move with a source: the members of every linked group it is in.
    public func linkedPartners(of id: UUID) -> [UUID] {
        var out: [UUID] = []
        for g in sourceGroups(of: id) where g.linked {
            for m in g.sources where m != id && !out.contains(m) { out.append(m) }
        }
        return out
    }

    static func wrap(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 360)
        if x > 180 { x -= 360 }
        if x <= -180 { x += 360 }
        return x
    }
}

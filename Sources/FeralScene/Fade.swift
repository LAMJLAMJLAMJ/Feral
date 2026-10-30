import Foundation

/// A snapshot recall fading the sources it stores from where they are to the stored values.
///
/// - Positions move in a straight line in the venue (Cartesian), so a source crossing the stage takes
///   the direct path.
/// - Gains, send levels and the LFE send move in dB; a send that starts or ends absent fades from or to
///   `floorDB` and is added at the start or dropped at the end.
/// - A source being unmuted unmutes at the start, one being muted mutes at the end.
///
/// The engine steps it every 20 ms and applies the values as `updateSources` commands, so the app,
/// the journal and the audio all follow the same path.
public struct SnapshotFade {
    public static let floorDB = -60.0

    public struct Part: Equatable {
        public let id: UUID
        /// Every value as it was when the fade started.
        public let from: SourceValues
        /// The stored values.
        public let to: SourceValues
    }

    public private(set) var parts: [Part]
    public let seconds: Double
    public let curve: FadeCurve
    public let snapshot: UUID

    /// A fade from the show as it is to the snapshot's values over `seconds` (none: the snapshot's own
    /// time) with `curve` (none: the snapshot's). Sources the snapshot stores that no longer exist are
    /// left out, as are sends to groups that no longer exist.
    public init(snapshot: Snapshot, state: ShowState, seconds: Double? = nil, curve: FadeCurve? = nil) {
        self.snapshot = snapshot.id
        self.seconds = max(0, seconds ?? snapshot.fadeSeconds)
        self.curve = curve ?? snapshot.curve
        parts = snapshot.sources.compactMap { stored -> Part? in
            guard let s = state.source(stored.id) else { return nil }
            var to = stored.values
            to.sends = to.sends?.filter { state.group($0.group) != nil }
            return Part(id: s.id, from: state.values(of: s), to: to)
        }
    }

    public var sources: [UUID] { parts.map(\.id) }

    /// Stops fading these sources (something else took them over); they stay where they are.
    public mutating func remove(_ ids: Set<UUID>) {
        parts.removeAll { ids.contains($0.id) }
    }

    public func isFinished(at elapsed: Double) -> Bool { elapsed >= seconds }

    /// The values every source should have `elapsed` seconds into the fade.
    public func updates(at elapsed: Double) -> [SourceUpdate] {
        let t = seconds <= 0 ? 1 : curve.apply(elapsed / seconds)
        return parts.map { SourceUpdate(id: $0.id, values: SnapshotFade.values(from: $0.from, to: $0.to, at: t)) }
    }

    /// The values a fraction `t` (after the curve) of the way from `from` to `to`, with only the
    /// fields `to` has.
    public static func values(from a: SourceValues, to b: SourceValues, at t: Double) -> SourceValues {
        func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        let done = t >= 1
        var v = SourceValues()
        if let p = b.position {
            let q = a.position ?? p
            v.position = done ? p : Position(lerp(q.x, p.x), lerp(q.y, p.y), lerp(q.z, p.z))
        }
        if let g = b.gainDB { v.gainDB = done ? g : lerp(a.gainDB ?? g, g) }
        if let w = b.width { v.width = done ? w : lerp(a.width ?? w, w) }
        if let m = b.mute { v.mute = done || !m ? m : (a.mute ?? m) }
        if let target = b.sends {
            if done {
                v.sends = target
            } else {
                let start = a.sends ?? []
                var order = target.map(\.group)
                for s in start where !order.contains(s.group) { order.append(s.group) }
                v.sends = order.map { g -> GroupSend in
                    let x = start.first { $0.group == g }?.gainDB ?? floorDB
                    let y = target.first { $0.group == g }?.gainDB ?? floorDB
                    return GroupSend(group: g, gainDB: lerp(x, y))
                }
            }
        }
        if b.lfeOff != nil || b.lfeDB != nil {
            let y = b.lfeOff == true ? nil : b.lfeDB
            if done {
                if let y { v.lfeDB = y } else { v.lfeOff = true }
            } else {
                let x = a.lfeOff == true ? nil : a.lfeDB
                if x == nil && y == nil { v.lfeOff = true } else { v.lfeDB = lerp(x ?? floorDB, y ?? floorDB) }
            }
        }
        return v
    }
}

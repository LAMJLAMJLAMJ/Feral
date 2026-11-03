import Foundation

/// A snapshot recall fading the sources it stores from where they are to the stored values.
///
/// - Positions move in a straight line in the venue (Cartesian), so a source crossing the stage takes
///   the direct path.
/// - Gains, send levels and the LFE send move in dB; a send that starts or ends absent fades from or to
///   `floorDB` and is added at the start or dropped at the end.
/// - A source being unmuted unmutes at the start, one being muted mutes at the end.
/// - Trim and delay move in a straight line, polarity flips halfway. EQ and compressor gains,
///   thresholds and ratios move linearly and frequencies, Qs and times geometrically; an EQ or
///   compressor turning on does so at the start (from flat), one turning off at the end; a high-pass
///   appearing sweeps up from 20 Hz, one going sweeps down to it. Distance modelling moves the same
///   way, from or to none (no roll-off, no air).
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
            if let r = to.reverb?.room, state.room(r) == nil { to.reverb = .off }
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
        if let x = b.trimDB { v.trimDB = done ? x : lerp(a.trimDB ?? x, x) }
        if let x = b.delayMS { v.delayMS = done ? x : lerp(a.delayMS ?? x, x) }
        // Polarity flips halfway.
        if let x = b.invert { v.invert = t >= 0.5 ? x : (a.invert ?? x) }
        if let x = b.eq { v.eq = done ? x : (a.eq ?? .flat).fading(to: x, at: t) }
        if let x = b.compressor { v.compressor = done ? x : (a.compressor ?? .off).fading(to: x, at: t) }
        if let x = b.distance { v.distance = done ? x : (a.distance ?? .off).fading(to: x, at: t) }
        if let x = b.reverb { v.reverb = done ? x : (a.reverb ?? .off).fading(to: x, at: t) }
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

private func lerp(_ x: Double, _ y: Double, _ t: Double) -> Double { x + (y - x) * t }
private func glide(_ x: Double, _ y: Double, _ t: Double) -> Double { x > 0 && y > 0 ? x * pow(y / x, t) : lerp(x, y, t) }

extension SourceEQ {
    /// This EQ a fraction `t` (after the curve, below 1) of the way to `to`.
    func fading(to b: SourceEQ, at t: Double) -> SourceEQ {
        // Off is flat: an EQ turning on starts flat and is on from the start; one turning off flattens
        // out and goes off at the end.
        let a = on ? self : SourceEQ(on: false, lowHz: b.lowHz, lowMidHz: b.lowMidHz, midHz: b.midHz, highMidHz: b.highMidHz,
                                     highHz: b.highHz)
        let target = b.on ? b : SourceEQ(on: false, lowHz: a.lowHz, lowMidHz: a.lowMidHz, lowMidQ: a.lowMidQ, midHz: a.midHz,
                                         midQ: a.midQ, highMidHz: a.highMidHz, highMidQ: a.highMidQ, highHz: a.highHz)
        var v = SourceEQ(on: on || b.on)
        switch (a.highPassHz, target.highPassHz) {
        case let (x?, y?): v.highPassHz = glide(x, y, t)
        case let (nil, y?): v.highPassHz = glide(20, y, t)
        case let (x?, nil): v.highPassHz = glide(x, 20, t)
        case (nil, nil): v.highPassHz = nil
        }
        v.lowHz = glide(a.lowHz, target.lowHz, t); v.lowDB = lerp(a.lowDB, target.lowDB, t)
        v.lowMidHz = glide(a.lowMidHz, target.lowMidHz, t); v.lowMidDB = lerp(a.lowMidDB, target.lowMidDB, t)
        v.lowMidQ = glide(a.lowMidQ, target.lowMidQ, t)
        v.midHz = glide(a.midHz, target.midHz, t); v.midDB = lerp(a.midDB, target.midDB, t); v.midQ = glide(a.midQ, target.midQ, t)
        v.highMidHz = glide(a.highMidHz, target.highMidHz, t); v.highMidDB = lerp(a.highMidDB, target.highMidDB, t)
        v.highMidQ = glide(a.highMidQ, target.highMidQ, t)
        v.highHz = glide(a.highHz, target.highHz, t); v.highDB = lerp(a.highDB, target.highDB, t)
        return v
    }
}

extension Compressor {
    /// This compressor a fraction `t` (after the curve, below 1) of the way to `to`.
    func fading(to b: Compressor, at t: Double) -> Compressor {
        // Off is a ratio of 1 and no makeup: one turning on starts there, one turning off ends there.
        var a = self, target = b
        if !a.on { a.ratio = 1; a.makeupDB = 0; a.bands = a.bands.map { var x = $0; x.ratio = 1; x.gainDB = 0; return x } }
        if !target.on { target.ratio = 1; target.makeupDB = 0; target.bands = target.bands.map { var x = $0; x.ratio = 1; x.gainDB = 0; return x } }
        var v = target
        v.on = on || b.on
        // The mode changes at the start when going multiband, at the end when leaving it.
        v.multiband = b.multiband || multiband
        v.thresholdDB = lerp(a.thresholdDB, target.thresholdDB, t)
        v.ratio = lerp(a.ratio, target.ratio, t)
        v.attackMS = glide(a.attackMS, target.attackMS, t)
        v.releaseMS = glide(a.releaseMS, target.releaseMS, t)
        v.makeupDB = lerp(a.makeupDB, target.makeupDB, t)
        v.crossoverLowHz = glide(a.crossoverLowHz, target.crossoverLowHz, t)
        v.crossoverHighHz = glide(a.crossoverHighHz, target.crossoverHighHz, t)
        if a.bands.count == target.bands.count {
            v.bands = zip(a.bands, target.bands).map { x, y in
                CompressorBand(thresholdDB: lerp(x.thresholdDB, y.thresholdDB, t), ratio: lerp(x.ratio, y.ratio, t),
                               attackMS: glide(x.attackMS, y.attackMS, t), releaseMS: glide(x.releaseMS, y.releaseMS, t),
                               gainDB: lerp(x.gainDB, y.gainDB, t))
            }
        }
        return v
    }
}

extension SourceDistance {
    /// This distance modelling a fraction `t` (after the curve, below 1) of the way to `to`.
    func fading(to b: SourceDistance, at t: Double) -> SourceDistance {
        // Off is no roll-off and no air: one turning on starts there, one turning off ends there.
        var a = self, target = b
        if !a.on { a.rolloffDB = 0; a.air = 0; a.referenceM = b.referenceM }
        if !target.on { target.rolloffDB = 0; target.air = 0; target.referenceM = a.referenceM }
        return SourceDistance(on: on || b.on, rolloffDB: lerp(a.rolloffDB, target.rolloffDB, t),
                              referenceM: glide(a.referenceM, target.referenceM, t), air: lerp(a.air, target.air, t))
    }
}

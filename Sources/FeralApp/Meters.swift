#if canImport(SwiftUI) && os(macOS)
import FeralControl
import FeralScene
import SwiftUI

/// The engine's level meters with meter ballistics: peaks fall back slowly, the highest peak holds
/// for two seconds, and a clip stays lit until it is cleared. The engine sends 20 frames a second.
final class MeterStore: ObservableObject {
    struct Channel: Equatable {
        /// dBFS, falling back at 24 dB a second after a peak.
        var peak: Float = MeterFrame.silence
        /// dBFS, averaged over about 300 ms by the engine.
        var rms: Float = MeterFrame.silence
        /// The highest peak in the last two seconds.
        var hold: Float = MeterFrame.silence
        var holdUntil = Date.distantPast
        /// A peak reached full scale since the clips were last cleared.
        var clipped = false
    }

    /// A peak at or above this lights the clip.
    static let clipDB: Float = -0.1
    /// How far a displayed peak falls in one frame (24 dB a second at 20 frames a second).
    static let fallPerFrame: Float = 1.2

    @Published private(set) var inputs: [Channel] = []
    @Published private(set) var outputs: [Channel] = []
    @Published private(set) var firstInputChannel = 1
    @Published private(set) var firstOutputChannel = 1
    /// The render's highest share of a buffer's time lately (1 is 100 %).
    @Published private(set) var load: Float = 0
    /// Frames are arriving.
    @Published private(set) var live = false

    func update(_ frame: MeterFrame) {
        let now = Date()
        inputs = Self.step(inputs, peak: frame.inputPeak, rms: frame.inputRMS, now: now)
        outputs = Self.step(outputs, peak: frame.outputPeak, rms: frame.outputRMS, now: now)
        if firstInputChannel != frame.firstInputChannel { firstInputChannel = frame.firstInputChannel }
        if firstOutputChannel != frame.firstOutputChannel { firstOutputChannel = frame.firstOutputChannel }
        load = frame.load
        if !live { live = true }
    }

    func reset() {
        inputs = []
        outputs = []
        load = 0
        live = false
    }

    func clearClips() {
        for i in inputs.indices { inputs[i].clipped = false }
        for i in outputs.indices { outputs[i].clipped = false }
    }

    var anyClipped: Bool { inputs.contains { $0.clipped } || outputs.contains { $0.clipped } }

    /// Engine input n (from 1), if the engine has it.
    func input(_ n: Int) -> Channel? { inputs.indices.contains(n - 1) ? inputs[n - 1] : nil }
    func output(_ n: Int) -> Channel? { outputs.indices.contains(n - 1) ? outputs[n - 1] : nil }

    private static func step(_ old: [Channel], peak: [Float], rms: [Float], now: Date) -> [Channel] {
        var out = old.count == peak.count ? old : [Channel](repeating: Channel(), count: peak.count)
        for i in out.indices {
            var c = out[i]
            let p = peak[i]
            c.peak = max(p, c.peak - fallPerFrame, MeterFrame.silence)
            c.rms = i < rms.count ? rms[i] : MeterFrame.silence
            if p >= c.hold || now > c.holdUntil {
                c.hold = p
                c.holdUntil = now + 2
            }
            if p >= clipDB { c.clipped = true }
            out[i] = c
        }
        return out
    }
}

/// Where a level sits on a meter: -60 dBFS at the bottom, 0 at the top.
enum MeterScale {
    static let floor: Float = -60

    static func fraction(_ db: Float) -> CGFloat {
        CGFloat(max(0, min(1, (db - floor) / -floor)))
    }

    /// Green to -18 dBFS, yellow to -6, then red.
    static let gradient = Gradient(stops: [
        .init(color: Color(red: 0.20, green: 0.75, blue: 0.35), location: 0),
        .init(color: Color(red: 0.30, green: 0.82, blue: 0.38), location: fraction(-18)),
        .init(color: Color(red: 0.95, green: 0.80, blue: 0.20), location: fraction(-17.9)),
        .init(color: Color(red: 0.98, green: 0.62, blue: 0.15), location: fraction(-6)),
        .init(color: Color(red: 0.95, green: 0.25, blue: 0.20), location: fraction(-5.9)),
        .init(color: Color(red: 0.95, green: 0.20, blue: 0.20), location: 1),
    ])

    /// The meter's colour at a level, for one-colour marks such as the plan's.
    static func color(_ db: Float) -> Color {
        db >= -6 ? Color(red: 0.95, green: 0.25, blue: 0.20) : db >= -18 ? Color(red: 0.95, green: 0.80, blue: 0.20)
            : Color(red: 0.30, green: 0.82, blue: 0.38)
    }

    static func text(_ db: Float) -> String { db <= floor ? "-inf" : String(format: "%.1f", db) }
}

/// One channel's meter: RMS solid, peak paler above it, the held peak as a line, and a clip light at
/// the end.
struct MeterBar: View {
    let channel: MeterStore.Channel?
    var vertical = true
    /// Clears the clip lights; a click on a meter that has clipped calls it.
    var clear: (() -> Void)?

    var body: some View {
        Canvas { ctx, size in
            let c = channel ?? MeterStore.Channel()
            let clip: CGFloat = vertical ? min(4, size.height * 0.05) : min(4, size.width * 0.05)
            let length = (vertical ? size.height : size.width) - clip - 1
            func span(_ to: CGFloat) -> CGRect {
                vertical ? CGRect(x: 0, y: size.height - to * length, width: size.width, height: to * length)
                    : CGRect(x: 0, y: 0, width: to * length, height: size.height)
            }
            let full = span(1)
            ctx.fill(Path(full), with: .color(.primary.opacity(0.08)))
            let start = vertical ? CGPoint(x: 0, y: size.height) : CGPoint(x: 0, y: 0)
            let end = vertical ? CGPoint(x: 0, y: size.height - length) : CGPoint(x: length, y: 0)
            let shading = GraphicsContext.Shading.linearGradient(MeterScale.gradient, startPoint: start, endPoint: end)
            var faded = ctx
            faded.opacity = 0.4
            faded.fill(Path(span(MeterScale.fraction(c.peak))), with: shading)
            ctx.fill(Path(span(MeterScale.fraction(c.rms))), with: shading)
            if c.hold > MeterScale.floor {
                let f = MeterScale.fraction(c.hold)
                let line = vertical ? CGRect(x: 0, y: size.height - f * length - 1, width: size.width, height: 1.5)
                    : CGRect(x: f * length - 1, y: 0, width: 1.5, height: size.height)
                ctx.fill(Path(line), with: .color(MeterScale.color(c.hold)))
            }
            let light = vertical ? CGRect(x: 0, y: 0, width: size.width, height: clip)
                : CGRect(x: size.width - clip, y: 0, width: clip, height: size.height)
            ctx.fill(Path(light), with: .color(c.clipped ? Color.red : Color.primary.opacity(0.08)))
        }
        .accessibilityLabel(channel.map { "peak \(MeterScale.text($0.peak)) dB, RMS \(MeterScale.text($0.rms)) dB" } ?? "no level")
        .simultaneousGesture(TapGesture().onEnded { if channel?.clipped == true { clear?() } })
        .help(channel?.clipped == true ? "Clipped. Click to clear the clip lights." : "")
    }
}

/// A source's or speaker's meter with its levels in numbers, for the inspector.
struct MeterReadout: View {
    let title: String
    let channel: MeterStore.Channel?
    var clear: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let c = channel {
                    Text("peak \(MeterScale.text(c.hold))  rms \(MeterScale.text(c.rms)) dBFS")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(c.clipped ? Color.red : Color.secondary)
                } else {
                    Text("no meter").font(.caption).foregroundStyle(.secondary)
                }
            }
            MeterBar(channel: channel, vertical: false, clear: clear).frame(height: 10)
        }
    }
}

/// The meter bridge under the plan: every engine output a speaker uses (or all of them), labelled with
/// the speaker and the device channel. Click a meter to select its speaker. Input levels are next to
/// the sources (sidebar, plan, inspector).
struct MeterBridge: View {
    @ObservedObject var meters: MeterStore
    let state: ShowState
    @Binding var selection: Selection?
    /// Unhidden; when hidden only the title bar stays, to unhide it from.
    @Binding var shown: Bool
    @AppStorage("meterAllChannels") private var allChannels = false

    /// One strip's height: half of what it first was.
    static let stripHeight: CGFloat = 70

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { withAnimation(.easeInOut(duration: 0.15)) { shown.toggle() } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: shown ? "chevron.down" : "chevron.right").font(.caption2.bold())
                        Text("OUTPUT METERS").font(.caption2.bold())
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(shown ? "Hide the output meters (⇧⌘M)" : "Show the output meters (⇧⌘M)")
                if shown {
                    Toggle("All channels", isOn: $allChannels).toggleStyle(.checkbox).font(.caption)
                        .help("Show every engine output, not only the ones speakers use")
                    Spacer()
                    if meters.anyClipped {
                        Button("Clear clips") { meters.clearClips() }.help("Or click any clipped meter").font(.caption).buttonStyle(.borderless).foregroundStyle(.red)
                    }
                    Text(meters.live ? String(format: "render load %.0f %%", meters.load * 100) : "no meters from the engine")
                        .font(.caption.monospacedDigit()).foregroundStyle(meters.load > 0.8 ? Color.red : Color.secondary)
                    Text("-60 to 0 dBFS · the numbers are the peak, held 2 s").font(.caption).foregroundStyle(.secondary)
                } else {
                    Spacer()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            if shown {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 2) {
                        section("OUT", outputStrips)
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                }
                .frame(height: Self.stripHeight + 10)
            }
        }
        .background(.bar)
    }

    fileprivate struct Strip: Identifiable {
        let id: String
        let number: Int
        let name: String
        let device: Int
        let color: Color
        let channel: MeterStore.Channel?
        let target: Selection?
    }

    private var outputStrips: [Strip] {
        let count = meters.outputs.count
        guard count > 0 else { return [] }
        var byOutput: [Int: Speaker] = [:]
        for s in state.system.speakers where byOutput[s.output] == nil { byOutput[s.output] = s }
        var groupOf: [UUID: SpeakerGroup] = [:]
        for g in state.show.groups { for s in g.speakers where groupOf[s] == nil { groupOf[s] = g } }
        return (1...count).compactMap { n in
            let s = byOutput[n]
            guard allChannels || s != nil else { return nil }
            return Strip(id: "out\(n)", number: n, name: s.map { $0.name ?? "spk \($0.number)" } ?? "",
                         device: meters.firstOutputChannel + n - 1, color: s.flatMap { groupOf[$0.id]?.color } ?? .secondary,
                         channel: meters.output(n), target: s.map { .speaker($0.id) })
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ strips: [Strip]) -> some View {
        if strips.isEmpty {
            Text(meters.live ? "\(title): nothing the show uses" : "\(title): waiting for meters")
                .font(.caption).foregroundStyle(.secondary).frame(height: MeterBridge.stripHeight)
        } else {
            ForEach(strips) { strip in
                StripView(title: title, strip: strip, selected: strip.target != nil && selection == strip.target)
                    .onTapGesture {
                        // A click on a clipped meter clears the clip lights; on any meter it selects the speaker.
                        if strip.channel?.clipped == true { meters.clearClips() }
                        if let t = strip.target { selection = t }
                    }
            }
        }
    }
}

/// One channel on the meter bridge.
private struct StripView: View {
    let title: String
    let strip: MeterBridge.Strip
    let selected: Bool

    private var help: String {
        var text = "\(title) \(strip.number)"
        if !strip.name.isEmpty { text += ": \(strip.name)" }
        text += ", device channel \(strip.device)"
        if let c = strip.channel { text += ". Peak \(MeterScale.text(c.hold)), RMS \(MeterScale.text(c.rms)) dBFS" }
        return text
    }

    /// The held peak as a number: "-12", "-3.5", "-inf".
    private var reading: String {
        guard let c = strip.channel, c.hold > MeterScale.floor else { return "-inf" }
        return c.hold > -10 ? String(format: "%.1f", c.hold) : String(format: "%.0f", c.hold)
    }

    var body: some View {
        VStack(spacing: 1) {
            Text(reading)
                .font(.system(size: 8, weight: .medium).monospacedDigit())
                .foregroundStyle(strip.channel?.clipped == true ? Color.red : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            MeterBar(channel: strip.channel).frame(width: 8).frame(maxHeight: .infinity)
            Text(String(strip.number)).font(.system(size: 8, weight: .semibold).monospacedDigit())
            Rectangle().fill(strip.color).frame(width: 14, height: 2)
        }
        .frame(width: 28, height: MeterBridge.stripHeight)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.accentColor.opacity(0.2) : Color.clear))
        .contentShape(Rectangle())
        .help(help)
    }
}
#endif

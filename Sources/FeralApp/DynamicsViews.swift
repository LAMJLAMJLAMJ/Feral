#if canImport(SwiftUI) && os(macOS)
import FeralControl
import FeralScene
import SwiftUI

/// A source's channel EQ: on, high-pass, and low shelf, mid peak and high shelf, with its curve.
struct EQControls: View {
    let eq: SourceEQ
    let set: (SourceEQ) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("EQ on", isOn: Binding(get: { eq.on }, set: { on in var e = eq; e.on = on; set(e) }))
            EQCurve(eq: eq).frame(height: 70)
            Toggle("High-pass", isOn: Binding(get: { eq.highPassHz != nil },
                                              set: { on in var e = eq; e.highPassHz = on ? 80 : nil; set(e) }))
            if let hp = eq.highPassHz {
                row("HPF") { FrequencySlider(hz: hp) { var e = eq; e.highPassHz = $0; set(e) } }
            }
            Divider()
            row("Low") { GainSlider(db: eq.lowDB) { var e = eq; e.lowDB = $0; set(e) } }
            row("") { FrequencySlider(hz: eq.lowHz) { var e = eq; e.lowHz = $0; set(e) } }
            Divider()
            row("Mid") { GainSlider(db: eq.midDB) { var e = eq; e.midDB = $0; set(e) } }
            row("") { FrequencySlider(hz: eq.midHz) { var e = eq; e.midHz = $0; set(e) } }
            row("Q") {
                LevelSlider(value: eq.midQ, range: 0.3...8, step: 0.1, unit: "", format: { String(format: "Q %.1f", $0) }) {
                    var e = eq; e.midQ = $0; set(e)
                }
            }
            Divider()
            row("High") { GainSlider(db: eq.highDB) { var e = eq; e.highDB = $0; set(e) } }
            row("") { FrequencySlider(hz: eq.highHz) { var e = eq; e.highHz = $0; set(e) } }
            HStack {
                Spacer()
                Button("Flatten") { var e = SourceEQ.flat; e.on = eq.on; set(e) }
                    .help("Every band back to 0 dB and the high-pass off")
            }
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            content()
        }
    }
}

/// A source's compressor: on, threshold, ratio, attack, release, makeup, and its gain reduction now.
struct CompressorControls: View {
    let compressor: Compressor
    /// dB of gain reduction now; none while the meters are off.
    let reduction: Float?
    let set: (Compressor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Compressor on", isOn: Binding(get: { compressor.on }, set: { on in var c = compressor; c.on = on; set(c) }))
                Spacer()
                if let reduction {
                    ReductionBar(db: compressor.on ? reduction : 0, vertical: false).frame(width: 90, height: 8)
                    Text(String(format: "-%.1f dB", compressor.on ? reduction : 0)).font(.caption.monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                }
            }
            row("Thresh") {
                LevelSlider(value: compressor.thresholdDB, range: -60...0, step: 0.5, unit: "dB") { var c = compressor; c.thresholdDB = $0; set(c) }
            }
            row("Ratio") {
                LevelSlider(value: compressor.ratio, range: 1...20, step: 0.1, unit: "", format: { String(format: "%.1f:1", $0) }) {
                    var c = compressor; c.ratio = $0; set(c)
                }
            }
            row("Attack") {
                LevelSlider(value: log10(compressor.attackMS), range: -1...log10(200), step: 0.01, unit: "",
                            format: { Self.ms(pow(10, $0)) }) { var c = compressor; c.attackMS = Self.round(pow(10, $0)); set(c) }
            }
            row("Release") {
                LevelSlider(value: log10(compressor.releaseMS), range: log10(5)...log10(2000), step: 0.01, unit: "",
                            format: { Self.ms(pow(10, $0)) }) { var c = compressor; c.releaseMS = Self.round(pow(10, $0)); set(c) }
            }
            row("Makeup") {
                LevelSlider(value: compressor.makeupDB, range: 0...24, step: 0.5, unit: "dB") { var c = compressor; c.makeupDB = $0; set(c) }
            }
        }
    }

    static func ms(_ v: Double) -> String { v < 10 ? String(format: "%.1f ms", v) : String(format: "%.0f ms", v) }
    static func round(_ v: Double) -> Double { v < 10 ? (v * 10).rounded() / 10 : v.rounded() }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            content()
        }
    }
}

/// ±18 dB in half dB steps.
private struct GainSlider: View {
    let db: Double
    let set: (Double) -> Void

    var body: some View {
        LevelSlider(value: db, range: -18...18, step: 0.5, unit: "dB", set: set)
    }
}

/// 20 Hz to 20 kHz on a log scale.
private struct FrequencySlider: View {
    let hz: Double
    let set: (Double) -> Void

    var body: some View {
        LevelSlider(value: log10(hz), range: log10(20)...log10(20_000), step: 0.005, unit: "",
                    format: { Self.text(pow(10, $0)) }) { set(Self.round(pow(10, $0))) }
    }

    static func text(_ hz: Double) -> String {
        hz >= 1000 ? String(format: hz >= 10_000 ? "%.0f kHz" : "%.1f kHz", hz / 1000) : String(format: "%.0f Hz", hz)
    }

    /// Two or three significant figures, as a console shows them.
    static func round(_ hz: Double) -> Double {
        let unit = hz < 100 ? 1.0 : hz < 1000 ? 5 : hz < 10_000 ? 50 : 500
        return min(max((hz / unit).rounded() * unit, 20), 20_000)
    }
}

/// The EQ's response, 20 Hz to 20 kHz and ±18 dB.
struct EQCurve: View {
    let eq: SourceEQ

    var body: some View {
        Canvas { ctx, size in
            let rate = 48_000.0
            let quads = eq.bands.map { Biquad($0, sampleRate: rate) }
            func x(_ hz: Double) -> CGFloat { CGFloat((log10(hz) - log10(20)) / 3) * size.width }
            func y(_ db: Double) -> CGFloat { size.height / 2 - CGFloat(min(max(db, -18), 18) / 18) * size.height / 2 }
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(.primary.opacity(0.05)))
            for hz in [100.0, 1000, 10_000] {
                ctx.stroke(Path { $0.move(to: CGPoint(x: x(hz), y: 0)); $0.addLine(to: CGPoint(x: x(hz), y: size.height)) },
                           with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
            }
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y(0))); $0.addLine(to: CGPoint(x: size.width, y: y(0))) },
                       with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
            var path = Path()
            let steps = 120
            for i in 0...steps {
                let hz = pow(10, log10(20) + 3 * Double(i) / Double(steps))
                let db = quads.reduce(0) { $0 + $1.responseDB(at: hz, sampleRate: rate) }
                let p = CGPoint(x: x(hz), y: y(db))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.stroke(path, with: .color(eq.on ? .accentColor : .secondary), lineWidth: 1.5)
        }
    }
}

/// Gain reduction, 0 to 20 dB, filling down from the top (or in from the left).
struct ReductionBar: View {
    let db: Float
    let vertical: Bool

    var body: some View {
        GeometryReader { geo in
            let f = CGFloat(min(max(db, 0), 20) / 20)
            ZStack(alignment: vertical ? .top : .leading) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.1))
                RoundedRectangle(cornerRadius: 1.5).fill(Color.orange)
                    .frame(width: vertical ? geo.size.width : geo.size.width * f,
                           height: vertical ? geo.size.height * f : geo.size.height)
            }
        }
        .help(String(format: "Gain reduction %.1f dB", db))
    }
}

/// The mixer strip's EQ and COMP buttons: lit when on, each opening its controls.
struct ProcessingButtons: View {
    @ObservedObject var model: EngineModel
    let source: Source
    @State private var showEQ = false
    @State private var showComp = false

    var body: some View {
        let eq = source.eq ?? .flat
        let comp = source.compressor ?? .off
        HStack(spacing: 2) {
            button("EQ", on: eq.on, color: .blue) { showEQ.toggle() }
                .popover(isPresented: $showEQ, arrowEdge: .trailing) {
                    EQControls(eq: eq) { model.update(source.id, SourceValues(eq: $0)) }
                        .padding(12).frame(width: 300)
                }
            button("CMP", on: comp.on, color: .orange) { showComp.toggle() }
                .popover(isPresented: $showComp, arrowEdge: .trailing) {
                    LiveCompressorControls(model: model, meters: model.meters, source: source)
                        .padding(12).frame(width: 320)
                }
        }
    }

    private func button(_ title: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 9, weight: .bold))
                .frame(width: 28, height: 16)
                .foregroundStyle(on ? Color.white : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 3).fill(on ? color : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(title == "EQ" ? "EQ" : "Compressor")
    }
}

/// The compressor controls with the source's latest values and its gain reduction as it moves.
struct LiveCompressorControls: View {
    @ObservedObject var model: EngineModel
    @ObservedObject var meters: MeterStore
    let source: Source

    var body: some View {
        let live = model.state?.source(source.id) ?? source
        CompressorControls(compressor: live.compressor ?? .off, reduction: meters.reduction(input: live.input)) {
            model.update(source.id, SourceValues(compressor: $0))
        }
    }
}
#endif

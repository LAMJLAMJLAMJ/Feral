#if canImport(SwiftUI) && os(macOS)
import FeralControl
import FeralScene
import SwiftUI

/// A source's channel EQ: on, high-pass, low shelf, three peak bands and high shelf, with its curve.
struct EQControls: View {
    let eq: SourceEQ
    var spectrum: SpectrumFrame? = nil
    let set: (SourceEQ) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("EQ on", isOn: Binding(get: { eq.on }, set: { on in var e = eq; e.on = on; set(e) }))
            EQCurve(eq: eq, spectrum: spectrum).frame(height: 110)
            Toggle("High-pass", isOn: Binding(get: { eq.highPassHz != nil },
                                              set: { on in var e = eq; e.highPassHz = on ? 80 : nil; set(e) }))
            if let hp = eq.highPassHz {
                row("HPF") { FrequencySlider(hz: hp) { var e = eq; e.highPassHz = $0; set(e) } }
            }
            Divider()
            row("Low") { GainSlider(db: eq.lowDB) { var e = eq; e.lowDB = $0; set(e) } }
            row("") { FrequencySlider(hz: eq.lowHz) { var e = eq; e.lowHz = $0; set(e) } }
            peak("Lo mid", db: \.lowMidDB, hz: \.lowMidHz, q: \.lowMidQ)
            peak("Mid", db: \.midDB, hz: \.midHz, q: \.midQ)
            peak("Hi mid", db: \.highMidDB, hz: \.highMidHz, q: \.highMidQ)
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

    /// A peak band: gain, frequency and Q.
    @ViewBuilder
    private func peak(_ title: String, db: WritableKeyPath<SourceEQ, Double>, hz: WritableKeyPath<SourceEQ, Double>,
                      q: WritableKeyPath<SourceEQ, Double>) -> some View {
        Divider()
        row(title) { GainSlider(db: eq[keyPath: db]) { var e = eq; e[keyPath: db] = $0; set(e) } }
        row("") { FrequencySlider(hz: eq[keyPath: hz]) { var e = eq; e[keyPath: hz] = $0; set(e) } }
        row("") {
            LevelSlider(value: eq[keyPath: q], range: 0.3...8, step: 0.1, unit: "", format: { String(format: "Q %.1f", $0) }) {
                var e = eq; e[keyPath: q] = $0; set(e)
            }
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            content()
        }
    }
}

/// A source's compressor: on, threshold, ratio, attack, release, makeup, and its gain reduction now.
struct CompressorControls: View {
    let compressor: Compressor
    /// dB of gain reduction now; none while the meters are off.
    let reduction: Float?
    /// The same per band, multiband only.
    var bandReduction: [Float]? = nil
    var spectrum: SpectrumFrame? = nil
    let set: (Compressor) -> Void
    @State private var band = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Compressor on", isOn: Binding(get: { compressor.on }, set: { on in var c = compressor; c.on = on; set(c) }))
                Spacer()
                if let reduction {
                    ReductionBar(db: compressor.on ? reduction : 0, vertical: false).frame(width: 70, height: 8)
                    Text(String(format: "-%.1f dB", compressor.on ? reduction : 0)).font(.caption.monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                }
            }
            Picker("Mode", selection: Binding(get: { compressor.multiband }, set: { m in var c = compressor; c.multiband = m; set(c) })) {
                Text("Single").tag(false)
                Text("Multiband").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if compressor.multiband {
                multiband
            } else {
                dynamics(threshold: \.thresholdDB, ratio: \.ratio, attack: \.attackMS, release: \.releaseMS)
            }
            row("Makeup") {
                LevelSlider(value: compressor.makeupDB, range: 0...24, step: 0.5, unit: "dB") { var c = compressor; c.makeupDB = $0; set(c) }
            }
        }
    }

    @ViewBuilder
    private var multiband: some View {
        EQCurve(eq: nil, spectrum: spectrum, crossovers: [compressor.crossoverLowHz, compressor.crossoverHighHz]).frame(height: 80)
        row("Low x") {
            FrequencySlider(hz: compressor.crossoverLowHz) { v in
                var c = compressor; c.crossoverLowHz = min(v, c.crossoverHighHz / 2); set(c)
            }
        }
        row("High x") {
            FrequencySlider(hz: compressor.crossoverHighHz) { v in
                var c = compressor; c.crossoverHighHz = max(v, c.crossoverLowHz * 2); set(c)
            }
        }
        // The three bands' reduction side by side, and which one the controls below edit.
        HStack(spacing: 8) {
            ForEach(0..<Compressor.bandCount, id: \.self) { b in
                Button { band = b } label: {
                    VStack(spacing: 2) {
                        Text(["Low", "Mid", "High"][b]).font(.caption.bold())
                            .foregroundStyle(band == b ? Color.accentColor : Color.secondary)
                        ReductionBar(db: compressor.on ? (bandReduction.map { $0.indices.contains(b) ? $0[b] : 0 } ?? 0) : 0,
                                     vertical: false)
                            .frame(height: 6)
                    }
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(band == b ? Color.accentColor.opacity(0.15) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        let b = min(band, compressor.bands.count - 1)
        if b >= 0 {
            dynamics(threshold: \.bands[b].thresholdDB, ratio: \.bands[b].ratio, attack: \.bands[b].attackMS,
                     release: \.bands[b].releaseMS)
            row("Gain") {
                LevelSlider(value: compressor.bands[b].gainDB, range: -24...24, step: 0.5, unit: "dB") {
                    var c = compressor; c.bands[b].gainDB = $0; set(c)
                }
            }
        }
    }

    /// Threshold, ratio, attack and release, for the single compressor or one band.
    @ViewBuilder
    private func dynamics(threshold: WritableKeyPath<Compressor, Double>, ratio: WritableKeyPath<Compressor, Double>,
                          attack: WritableKeyPath<Compressor, Double>, release: WritableKeyPath<Compressor, Double>) -> some View {
        row("Thresh") {
            LevelSlider(value: compressor[keyPath: threshold], range: -60...0, step: 0.5, unit: "dB") {
                var c = compressor; c[keyPath: threshold] = $0; set(c)
            }
        }
        row("Ratio") {
            LevelSlider(value: compressor[keyPath: ratio], range: 1...20, step: 0.1, unit: "", format: { String(format: "%.1f:1", $0) }) {
                var c = compressor; c[keyPath: ratio] = $0; set(c)
            }
        }
        row("Attack") {
            LevelSlider(value: log10(compressor[keyPath: attack]), range: -1...log10(200), step: 0.01, unit: "",
                        format: { Self.ms(pow(10, $0)) }) { var c = compressor; c[keyPath: attack] = Self.round(pow(10, $0)); set(c) }
        }
        row("Release") {
            LevelSlider(value: log10(compressor[keyPath: release]), range: log10(5)...log10(2000), step: 0.01, unit: "",
                        format: { Self.ms(pow(10, $0)) }) { var c = compressor; c[keyPath: release] = Self.round(pow(10, $0)); set(c) }
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
    let eq: SourceEQ?
    /// The source's spectrum before (grey) and after (colour) processing, behind the curve.
    var spectrum: SpectrumFrame? = nil
    /// Multiband crossovers, drawn as lines with the bands named.
    var crossovers: [Double] = []

    /// The spectrum's scale: -90 to 0 dBFS over the full height.
    static let spectrumFloor: Float = -90

    var body: some View {
        Canvas { ctx, size in
            let rate = 48_000.0
            func x(_ hz: Double) -> CGFloat { CGFloat((log10(hz) - log10(20)) / 3) * size.width }
            func y(_ db: Double) -> CGFloat { size.height / 2 - CGFloat(min(max(db, -18), 18) / 18) * size.height / 2 }
            func sy(_ db: Float) -> CGFloat {
                CGFloat(min(max(db, Self.spectrumFloor), 0) / Self.spectrumFloor) * size.height
            }
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(.primary.opacity(0.05)))
            if let spectrum {
                func trace(_ values: [Float], closed: Bool) -> Path {
                    var p = Path()
                    for (i, v) in values.enumerated() {
                        let pt = CGPoint(x: x(Spectrum.frequency(i)), y: sy(v))
                        if i == 0 { p.move(to: closed ? CGPoint(x: pt.x, y: size.height) : pt); if closed { p.addLine(to: pt) } }
                        else { p.addLine(to: pt) }
                    }
                    if closed { p.addLine(to: CGPoint(x: size.width, y: size.height)); p.closeSubpath() }
                    return p
                }
                ctx.fill(trace(spectrum.pre, closed: true), with: .color(.secondary.opacity(0.25)))
                ctx.stroke(trace(spectrum.post, closed: false), with: .color(.teal.opacity(0.9)), lineWidth: 1)
            }
            for hz in [100.0, 1000, 10_000] {
                ctx.stroke(Path { $0.move(to: CGPoint(x: x(hz), y: 0)); $0.addLine(to: CGPoint(x: x(hz), y: size.height)) },
                           with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
            }
            for hz in crossovers {
                ctx.stroke(Path { $0.move(to: CGPoint(x: x(hz), y: 0)); $0.addLine(to: CGPoint(x: x(hz), y: size.height)) },
                           with: .color(.orange), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            if let eq {
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y(0))); $0.addLine(to: CGPoint(x: size.width, y: y(0))) },
                           with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
                let quads = eq.bands.map { Biquad($0, sampleRate: rate) }
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
}

/// The spectrum the engine sends for the open source, falling back smoothly (30 dB a second) so
/// it reads like an analyser rather than flickering.
final class SpectrumStore: ObservableObject {
    @Published private(set) var frame: SpectrumFrame?

    func update(_ new: SpectrumFrame) {
        guard let old = frame, old.input == new.input, old.pre.count == new.pre.count, old.post.count == new.post.count else {
            frame = new
            return
        }
        func fall(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map { max($1, $0 - 1.5) } }
        frame = SpectrumFrame(input: new.input, pre: fall(old.pre, new.pre), post: fall(old.post, new.post))
    }

    func clear() { frame = nil }

    /// Input n's spectrum (from 1), if it is the one arriving.
    func spectrum(input n: Int) -> SpectrumFrame? { frame?.input == n ? frame : nil }
}

/// Asks the engine for a source's spectrum while the view is on screen.
private struct AnalysesInput: ViewModifier {
    let model: EngineModel
    let input: Int

    func body(content: Content) -> some View {
        content
            .onAppear { model.wantSpectrum(input: input) }
            .onDisappear { model.dropSpectrum(input: input) }
            .onChange(of: input) { old, new in
                model.dropSpectrum(input: old)
                model.wantSpectrum(input: new)
            }
    }
}

/// The EQ controls with the source's latest values and its spectrum.
struct LiveEQControls: View {
    @ObservedObject var model: EngineModel
    @ObservedObject var spectrum: SpectrumStore
    let source: Source

    var body: some View {
        let live = model.state?.source(source.id) ?? source
        EQControls(eq: live.eq ?? .flat, spectrum: spectrum.spectrum(input: live.input)) {
            model.update(source.id, SourceValues(eq: $0))
        }
        .modifier(AnalysesInput(model: model, input: live.input))
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
                    LiveEQControls(model: model, spectrum: model.spectrum, source: source)
                        .padding(12).frame(width: 340)
                }
            button("CMP", on: comp.on, color: .orange) { showComp.toggle() }
                .popover(isPresented: $showComp, arrowEdge: .trailing) {
                    LiveCompressorControls(model: model, meters: model.meters, spectrum: model.spectrum, source: source)
                        .padding(12).frame(width: 340)
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
    @ObservedObject var spectrum: SpectrumStore
    let source: Source

    var body: some View {
        let live = model.state?.source(source.id) ?? source
        CompressorControls(compressor: live.compressor ?? .off, reduction: meters.reduction(input: live.input),
                           bandReduction: meters.bandReduction(input: live.input),
                           spectrum: spectrum.spectrum(input: live.input)) {
            model.update(source.id, SourceValues(compressor: $0))
        }
        .modifier(AnalysesInput(model: model, input: live.input))
    }
}
#endif

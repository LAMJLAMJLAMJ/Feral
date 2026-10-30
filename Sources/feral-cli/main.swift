// feral-cli: offline checks and renders through the same render core the engine plays live.
//
//   feral-cli check                                 run the known-answer checks
//   feral-cli taps    [--config PATH]               every source's gain and delay per speaker
//   feral-cli impulse [--config PATH] [--source N]  render an impulse and measure what each output gets
//   feral-cli render  [--config PATH] [IN.wav] OUT.wav [--seconds S] [--tail S]
//
// --config defaults to the engine's own settings, ~/Library/Application Support/Feral/engine.json.
import FeralOffline
import FeralScene
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("feral-cli: \(message)\n".utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"
if !args.isEmpty { args.removeFirst() }

var configURL = EngineConfig.defaultURL
var source: Int?
var seconds: Double?
var tail = 1.0
var files: [String] = []
while !args.isEmpty {
    let arg = args.removeFirst()
    func value() -> String {
        guard !args.isEmpty else { fail("\(arg) needs a value") }
        return args.removeFirst()
    }
    switch arg {
    case "--config": configURL = URL(fileURLWithPath: value())
    case "--source":
        guard let n = Int(value()) else { fail("--source needs an input number") }
        source = n
    case "--seconds":
        guard let n = Double(value()) else { fail("--seconds needs a number") }
        seconds = n
    case "--tail":
        guard let n = Double(value()) else { fail("--tail needs a number") }
        tail = n
    default:
        if arg.hasPrefix("--") { fail("unknown option \(arg); try feral-cli help") }
        files.append(arg)
    }
}

func loadConfig() -> EngineConfig {
    do { return try EngineConfig.load(from: configURL) } catch {
        fail("\(configURL.path): \(error)")
    }
}

/// Pads text on the right to a width, for columns.
func pad(_ s: String, _ width: Int) -> String { s.count >= width ? s : s + String(repeating: " ", count: width - s.count) }

func db(_ g: Float) -> String { g == 0 ? "-inf" : String(format: "%+.1f", 20 * log10(Double(abs(g)))) }

switch command {
case "check":
    let results = KnownAnswers.run()
    for r in results {
        print("\(r.passed ? "PASS" : "FAIL")  \(r.name)")
        if !r.passed { print("      \(r.detail)") }
    }
    let failed = results.filter { !$0.passed }.count
    print(failed == 0 ? "All \(results.count) checks passed." : "\(failed) of \(results.count) checks FAILED.")
    exit(failed == 0 ? 0 : 1)

case "taps":
    let config = loadConfig()
    guard config.isSpatial else { fail("\(configURL.path) has no groups, so nothing is rendered spatially") }
    do {
        let renderer = try SpatialRenderer(config: config)
        for line in renderer.groupSummaries { print("group \(line)") }
        let names = Dictionary(config.speakers.map { ($0.output, $0.label) }, uniquingKeysWith: { a, _ in a })
        for (i, s) in config.sources.enumerated() {
            let p = s.position
            print("\nsource \(s.label) at [\(p.x), \(p.y), \(p.z)]" + (s.mute ? " (muted)" : ""))
            for t in renderer.allTaps[i].sorted(by: { $0.delay != $1.delay ? $0.delay < $1.delay : $0.output < $1.output }) {
                let name = names[t.output + 1] ?? "output \(t.output + 1)"
                let delay = t.delayed ? String(format: "%7.2f ms", t.delay * 1000) : "          "
                let level = String(repeating: " ", count: max(0, 6 - db(t.gain).count)) + db(t.gain)
                print("  \(pad(name, 28)) \(pad(t.group, 10)) \(level) dB  \(delay)")
            }
        }
    } catch { fail("\(error)") }

case "impulse":
    var config = loadConfig()
    config.testSignal = .off
    config.testMotion = nil
    let input = source ?? config.sources.first?.input ?? 1
    guard (1...max(config.inputs, 1)).contains(input) else { fail("--source must be an input from 1 to \(config.inputs)") }
    do {
        let renderer = try OfflineRenderer(config: config)
        let arrivals = renderer.impulse(input: input, seconds: 1.2)
        let names = Dictionary(config.speakers.map { ($0.output, $0.label) }, uniquingKeysWith: { a, _ in a })
        print("impulse into input \(input): \(arrivals.count) output(s) reached (arrival is the loudest sample)")
        for a in arrivals.sorted(by: { $0.milliseconds != $1.milliseconds ? $0.milliseconds < $1.milliseconds : $0.output < $1.output }) {
            let name = names[a.output] ?? "output \(a.output)"
            print("  \(pad(name, 28)) " + String(format: "%8.2f ms  %+6.1f dB", a.milliseconds, a.levelDB)
                  + (a.inverted ? "  inverted" : ""))
        }
    } catch { fail("\(error)") }

case "render":
    guard (1...2).contains(files.count) else { fail("render needs an output file (and optionally an input file first)") }
    var config = loadConfig()
    var input: [[Float]] = []
    var length = Int((seconds ?? 10) * config.sampleRate)
    if files.count == 2 {
        do {
            let wav = try WAV.read(URL(fileURLWithPath: files[0]))
            guard wav.sampleRate == config.sampleRate else {
                fail("\(files[0]) is at \(Int(wav.sampleRate)) Hz but the engine runs at \(Int(config.sampleRate)) Hz")
            }
            input = wav.channels
            length = seconds.map { Int($0 * config.sampleRate) } ?? wav.frames + Int(tail * config.sampleRate)
            if input.count > config.inputs { print("note: the file has \(input.count) channels; only the first \(config.inputs) are engine inputs") }
        } catch { fail("\(error)") }
    } else if config.testSignal == .off {
        print("note: no input file and no testSignal in the config, so the render is silent")
    }
    config.bufferFrames = min(config.bufferFrames, 4096)
    do {
        let renderer = try OfflineRenderer(config: config)
        let started = Date()
        let out = renderer.render(length: length, input: input)
        try WAV(sampleRate: config.sampleRate, channels: out).write(to: URL(fileURLWithPath: files.last!))
        let peak = out.map { $0.map { abs($0) }.max() ?? 0 }.max() ?? 0
        print("wrote \(files.last!): \(out.count) channels, "
              + String(format: "%.1f s, peak ", Double(length) / config.sampleRate) + db(peak)
              + String(format: " dBFS, rendered in %.1f s", Date().timeIntervalSince(started)))
    } catch { fail("\(error)") }

default:
    print("""
    feral-cli: offline checks and renders through Feral's render core

    feral-cli check                                   run the known-answer checks
    feral-cli taps    [--config PATH]                 every source's gain and delay per speaker
    feral-cli impulse [--config PATH] [--source N]    play an impulse into input N and measure each output
    feral-cli render  [--config PATH] [IN.wav] OUT.wav [--seconds S] [--tail S]
                                                      render a file (or the test signal) to a multichannel WAV

    --config defaults to \(EngineConfig.defaultURL.path)
    """)
    exit(command == "help" || command == "-h" || command == "--help" ? 0 : 2)
}

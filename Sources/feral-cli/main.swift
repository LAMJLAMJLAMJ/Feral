// feral-cli: offline checks and renders through the same render core the engine plays live, show
// files, and the running engine from Terminal.
//
//   feral-cli check                                 run the known-answer checks
//   feral-cli taps    [--config PATH]               every source's gain and delay per speaker
//   feral-cli impulse [--config PATH] [--source N]  render an impulse and measure what each output gets
//   feral-cli render  [--config PATH] [IN.wav] OUT.wav [--seconds S] [--tail S]
//   feral-cli show import OUT.feralshow [--config PATH]   make a show from engine.json's layout keys
//   feral-cli show info [PATH.feralshow]            what a show holds
//   feral-cli status | go [CUE] | recall SNAPSHOT [--fade S] | move SOURCE X Y [Z] | store NAME [--fade S]
//             | cue NUMBER SNAPSHOT [--fade S] [--name N] [--follow] | stop | save     the running engine
//
// --config defaults to the engine's own settings, ~/Library/Application Support/Feral/engine.json.
// taps, impulse and render use the show engine.json names (or --show PATH), as the engine does.
import FeralControl
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
var showPath: String?
var source: Int?
var seconds: Double?
var tail = 1.0
var fade: Double?
var cueName: String?
var follow = false
var host = "127.0.0.1"
var port: Int?
var files: [String] = []
while !args.isEmpty {
    let arg = args.removeFirst()
    func value() -> String {
        guard !args.isEmpty else { fail("\(arg) needs a value") }
        return args.removeFirst()
    }
    switch arg {
    case "--config": configURL = URL(fileURLWithPath: value())
    case "--show": showPath = value()
    case "--fade":
        guard let n = Double(value()) else { fail("--fade needs a number of seconds") }
        fade = n
    case "--name": cueName = value()
    case "--follow": follow = true
    case "--host": host = value()
    case "--port":
        guard let n = Int(value()) else { fail("--port needs a number") }
        port = n
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
        if arg.hasPrefix("--") && Double(arg) == nil { fail("unknown option \(arg); try feral-cli help") }
        files.append(arg)
    }
}

/// engine.json's settings alone.
func loadEngineConfig() -> EngineConfig {
    do { return try EngineConfig.load(from: configURL) } catch {
        fail("\(configURL.path): \(error)")
    }
}

/// engine.json's show (or --show), with its journal replayed.
func openShow(_ config: EngineConfig) -> ShowFile.Opened {
    var c = config
    if let showPath { c.show = NSString(string: showPath).standardizingPath.hasPrefix("/") ? showPath
                      : FileManager.default.currentDirectoryPath + "/" + showPath }
    do {
        let opened = try ShowFile.open(for: c, configURL: configURL)
        for p in opened.problems { print("note: \(p) (skipped)") }
        return opened
    } catch { fail("\(error)") }
}

/// engine.json's settings with its show's layout, as the engine plays them.
func loadConfig() -> EngineConfig {
    let config = loadEngineConfig()
    let opened = openShow(config)
    let c = opened.state.engineConfig(base: config)
    do { try c.validate() } catch { fail("\(opened.url.path): \(error)") }
    return c
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
        print("impulse into input \(input): \(arrivals.count) output(s) reached (arrival is the loudest sample; level is the energy)")
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

case "show":
    let sub = files.first ?? "info"
    switch sub {
    case "import":
        guard files.count == 2 else { fail("show import needs the new show's path: feral-cli show import My.feralshow") }
        let out = URL(fileURLWithPath: files[1])
        guard out.pathExtension == ShowFile.fileExtension else { fail("the show's name must end in .\(ShowFile.fileExtension)") }
        guard !FileManager.default.fileExists(atPath: out.path) else { fail("\(out.path) exists already") }
        let config = loadEngineConfig()
        do {
            let state = try ShowState.importing(config, name: out.deletingPathExtension().lastPathComponent)
            try state.engineConfig(base: config).validate()
            try ShowFile.save(state, to: out)
            print("wrote \(out.path): \(state.system.speakers.count) speaker(s), \(state.show.groups.count) group(s), "
                  + "\(state.show.sources.count) source(s)")
        } catch { fail("\(error)") }
    case "info":
        if files.count == 2 { showPath = files[1] }
        let opened = openShow(loadEngineConfig())
        let s = opened.state
        print("\(s.show.name): \(opened.url.path)" + (opened.exists ? "" : " (not saved yet: made from engine.json)"))
        if opened.replayed > 0 { print("\(opened.replayed) unsaved change(s) in its journal") }
        print("\nspeakers (\(s.system.speakers.count))")
        for sp in s.system.speakers.sorted(by: { $0.number < $1.number }) {
            let p = sp.position
            print("  \(pad(sp.label, 22)) output \(pad(String(sp.output), 4)) at [\(p.x), \(p.y), \(p.z)]"
                  + (s.system.lfeSpeakers.contains(sp.id) ? "  LFE" : ""))
        }
        print("\ngroups (\(s.show.groups.count))")
        for g in s.show.groups {
            let outs = g.speakers.compactMap { s.speaker($0)?.output }.map(String.init).joined(separator: ", ")
            print("  \(pad("\(g.number) \(g.name)", 22)) \(pad(g.renderer.rawValue, 6)) outputs \(outs)")
        }
        print("\nsources (\(s.show.sources.count))")
        for src in s.show.sources {
            let p = src.position
            let sends = src.sends.compactMap { send in s.group(send.group).map { "\($0.name) \(db(Float(pow(10, send.gainDB / 20))))" } }
            print("  \(pad(src.label, 22)) input \(pad(String(src.input), 4)) at [\(p.x), \(p.y), \(p.z)]"
                  + (src.mute ? " muted" : "") + "  sends: " + (sends.isEmpty ? "none" : sends.joined(separator: ", ")))
        }
        print("\nsnapshots (\(s.show.snapshots.count))")
        for snap in s.show.snapshots.sorted(by: { $0.number < $1.number }) {
            print("  \(pad(snap.label, 22)) \(snap.sources.count) source(s), fade \(snap.fadeSeconds) s \(snap.curve.rawValue)")
        }
        print("\ncues (\(s.show.cues.count))")
        for cue in s.orderedCues {
            let snap = cue.snapshot.flatMap { s.snapshot($0) }.map { "snapshot \($0.label)" } ?? "no snapshot"
            print("  \(pad(cue.label, 22)) \(snap)" + (cue.fadeSeconds.map { ", fade \($0) s" } ?? "")
                  + (cue.autoFollow ? ", auto-follow" : ""))
        }
    default:
        fail("show \(sub)? Try feral-cli show import My.feralshow, or feral-cli show info")
    }

case "status", "go", "recall", "move", "store", "cue", "stop", "save":
    #if canImport(Network)
    runEngineCommand(command, files)
    #else
    fail("talking to the engine needs macOS")
    #endif

default:
    print("""
    feral-cli: offline checks and renders through Feral's render core

    feral-cli check                                   run the known-answer checks
    feral-cli taps    [--config PATH]                 every source's gain and delay per speaker
    feral-cli impulse [--config PATH] [--source N]    play an impulse into input N and measure each output
    feral-cli render  [--config PATH] [IN.wav] OUT.wav [--seconds S] [--tail S]
                                                      render a file (or the test signal) to a multichannel WAV
    feral-cli show import OUT.feralshow               make a show from engine.json's speakers, groups and sources
    feral-cli show info [PATH.feralshow]              what a show holds (default: engine.json's show)

    The running engine:
    feral-cli status                                  the show, the current and next cue, the audio device
    feral-cli go [CUE]                                run the next cue, or cue CUE (a number such as 12.5)
    feral-cli recall SNAPSHOT [--fade S]              recall a snapshot (by number or name)
    feral-cli move SOURCE X Y [Z]                     move a source (by number) to X Y Z metres
    feral-cli store NAME [--fade S]                   store every source as a new snapshot
    feral-cli cue NUMBER SNAPSHOT [--fade S] [--name N] [--follow]   add a cue (or change cue NUMBER)
    feral-cli stop                                    stop every running fade where it is
    feral-cli save                                    save the show (and empty its journal)

    --config defaults to \(EngineConfig.defaultURL.path); --show PATH plays another show offline;
    --host and --port reach an engine on another Mac (default 127.0.0.1, engine.json's controlPort).
    """)
    exit(command == "help" || command == "-h" || command == "--help" ? 0 : 2)
}

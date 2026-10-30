// feral-engine: the headless engine process. launchd starts it at login and restarts it within
// about a second if it crashes (see launchd/local.feral.engine.plist and scripts/install-engine.sh).
//
//   feral-engine devices                       list Core Audio devices with their UIDs and channels
//   feral-engine init-config [--device X]      write engine.json with the defaults (128 by 128 passthrough)
//   feral-engine [run] [--config PATH]         run the engine (the default)
//
// While running: SIGHUP reloads engine.json (a new routing ramps in without a click; device changes
// reopen the device; a different show is opened), SIGTERM or SIGINT stops cleanly with exit status 0,
// which launchd does not restart. The show (a .feralshow package) is changed through the control
// link on port 9100: the Feral app and feral-cli.
import FeralScene
import Foundation

let version = "0.3 (milestone 3: show file and app)"

func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                            formatOptions: [.withInternetDateTime, .withFractionalSeconds])
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}

func fail(_ message: String) -> Never {
    log("error: \(message)")
    exit(2)
}

struct Options {
    var command = "run"
    var configURL = EngineConfig.defaultURL
    var device: String?
    var bufferFrames: Int?

    init(_ args: [String]) {
        var rest = args[...]
        if let first = rest.first, !first.hasPrefix("-") { command = first; rest = rest.dropFirst() }
        while let arg = rest.popFirst() {
            switch arg {
            case "--config":
                guard let path = rest.popFirst() else { fail("--config needs a path") }
                configURL = URL(fileURLWithPath: path)
            case "--device":
                guard let name = rest.popFirst() else { fail("--device needs a UID or name") }
                device = name
            case "--buffer":
                guard let n = rest.popFirst().flatMap(Int.init) else { fail("--buffer needs a number of frames") }
                bufferFrames = n
            case "--version": command = "version"
            case "-h", "--help": command = "help"
            default: fail("unknown option \(arg); try --help")
            }
        }
    }

    /// The config file with any command-line overrides applied.
    func loadConfig() throws -> EngineConfig {
        var config = FileManager.default.fileExists(atPath: configURL.path)
            ? try EngineConfig.load(from: configURL) : EngineConfig()
        if let device { config.device = device }
        if let bufferFrames { config.bufferFrames = bufferFrames }
        try config.validate()
        return config
    }
}

let options = Options(Array(CommandLine.arguments.dropFirst()))

switch options.command {
case "version":
    print("feral-engine \(version)")
    exit(0)
case "help":
    print("""
    feral-engine \(version)

    feral-engine devices                     list audio devices with their UIDs and channel counts
    feral-engine init-config [--device X]    write \(EngineConfig.defaultURL.path) with the defaults
    feral-engine [run]                       run the engine (launchd does this; see scripts/install-engine.sh)

    Options: --config PATH, --device UID-or-name, --buffer FRAMES
    """)
    exit(0)
case "init-config":
    if FileManager.default.fileExists(atPath: options.configURL.path) {
        fail("\(options.configURL.path) exists already; edit it, or delete it first")
    }
    do {
        var config = EngineConfig()
        config.device = options.device
        if let n = options.bufferFrames { config.bufferFrames = n }
        try config.validate()
        try config.save(to: options.configURL)
        print("Wrote \(options.configURL.path)")
    } catch { fail("\(error)") }
    exit(0)
default:
    break
}

#if os(macOS)
runOnMac(options)
#else
fail("feral-engine runs on macOS only; on Linux only the render core and its tests are built")
#endif

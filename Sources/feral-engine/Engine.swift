#if os(macOS)
import AVFoundation
import FeralIO
import FeralScene
import Foundation

/// The running engine: owns the render core and the audio device, and applies settings changes on
/// its control queue. Nothing here runs on the audio thread.
final class Engine {
    let queue = DispatchQueue(label: "feral.control", qos: .userInteractive)
    let options: Options
    let core: RenderCore
    private(set) var config: EngineConfig
    private var io: AudioEngineIO!
    private var timers: [DispatchSourceTimer] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var activity: NSObjectProtocol?
    private var lastReport = (late: UInt64(0), overloads: 0, skipped: UInt64(0))

    init(options: Options, config: EngineConfig) {
        self.options = options
        self.config = config
        core = RenderCore(sampleRate: config.sampleRate)
    }

    func start() {
        queue.async { [self] in
            log("feral-engine \(version) starting, pid \(getpid()), settings \(options.configURL.path)")
            // Keep the Mac awake and out of App Nap while the engine runs.
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical], reason: "Feral engine is rendering live audio")
            checkMicrophoneAccess()
            do { try publishRouting() } catch { log("error: \(error); playing silence until the routing is fixed") }
            io = AudioEngineIO(core: core, config: config, queue: queue, log: log)
            io.start()
            every(0.05) { [self] in core.collect() }
            every(10) { [self] in report(force: false) }
            every(300) { [self] in report(force: true) }
            onSignal(SIGHUP) { [self] in reload() }
            onSignal(SIGTERM) { [self] in shutdown("SIGTERM") }
            onSignal(SIGINT) { [self] in shutdown("SIGINT") }
        }
    }

    private func publishRouting() throws {
        let routing = try Routing(routes: config.routes, inputs: config.inputs, outputs: config.outputs)
        core.publish(routing)
        let routed = routing.gains.filter { $0 != 0 }.count
        log("routing: \(config.inputs) in by \(config.outputs) out, \(routed) gain(s) set"
            + (config.routes.isEmpty ? " (passthrough)" : " from \(config.routes.count) route(s)"))
    }

    /// Re-reads engine.json. A routing change ramps in over one buffer; device changes reopen it.
    private func reload() {
        let newConfig: EngineConfig
        do { newConfig = try options.loadConfig() } catch {
            log("reload: \(error); keeping the current settings")
            return
        }
        let old = config
        config = newConfig
        var deviceSettings = old
        deviceSettings.routes = newConfig.routes
        if deviceSettings != newConfig {
            if newConfig.sampleRate != old.sampleRate {
                log("reload: sampleRate changed; load figures use the old rate until the engine restarts")
            }
            io.reconfigure(newConfig)
        }
        do { try publishRouting() } catch { log("reload: \(error)") }
    }

    private func shutdown(_ signal: String) {
        log("\(signal): stopping")
        io.stop()
        report(force: true)
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        exit(0)
    }

    /// Logs a warning when buffers ran late since the last check, or a status line when forced.
    private func report(force: Bool) {
        let s = core.stats(resetMaxLoad: true)
        let overloads = io.overloads
        let skipped = io.skippedBuffers
        let late = s.lateBuffers - min(lastReport.late, s.lateBuffers)
        let newOverloads = overloads - lastReport.overloads
        let newSkipped = skipped - min(lastReport.skipped, skipped)
        lastReport = (s.lateBuffers, overloads, skipped)
        let line = "buffers \(s.buffers), peak load \(Int((s.maxLoad * 100).rounded())) %, "
            + "late \(s.lateBuffers), overloads \(overloads), skipped \(skipped), "
            + "state #\(s.currentState) (\(core.liveStates) held), faults \(io.faults), audio \(io.state)"
        if late > 0 || newOverloads > 0 || newSkipped > 0 {
            log("WARNING: in the last 10 s \(late) late, \(newOverloads) overload(s), \(newSkipped) skipped; \(line)")
        } else if force {
            log("status: \(line)")
        }
    }

    private func checkMicrophoneAccess() {
        guard config.inputs > 0 else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            log("asking macOS for audio input access")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                log(granted ? "audio input access granted"
                    : "audio input access denied: inputs will be silent. Allow Feral Engine in System Settings > Privacy & Security > Microphone")
            }
        default:
            log("WARNING: no audio input access, so inputs will be silent. Allow Feral Engine in "
                + "System Settings > Privacy & Security > Microphone")
        }
    }

    private func every(_ seconds: Double, _ action: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .milliseconds(Int(seconds * 100)))
        timer.setEventHandler(handler: action)
        timer.resume()
        timers.append(timer)
    }

    private func onSignal(_ number: Int32, _ action: @escaping () -> Void) {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
        source.setEventHandler(handler: action)
        source.resume()
        signalSources.append(source)
    }
}

func runOnMac(_ options: Options) -> Never {
    switch options.command {
    case "devices":
        do {
            let devices = try AudioDevices.all()
            for (n, d) in devices.enumerated() {
                let rates = d.availableSampleRates.map { "\(Int($0 / 1000))k" }.joined(separator: " ")
                print("\(n + 1). \(d.name)  [\(d.transport)]  in \(d.inputChannels), out \(d.outputChannels), "
                      + "\(Int(d.sampleRate)) Hz (\(rates))\(d.isAggregate ? "  AGGREGATE: not for live use" : "")")
                print("   UID: \(d.uid)")
            }
        } catch { fail("\(error)") }
        exit(0)
    case "run":
        let config: EngineConfig
        do { config = try options.loadConfig() } catch {
            // Exiting would make launchd restart us every second; wait for a fixed file instead.
            log("error: \(error). Fix \(options.configURL.path) and send SIGHUP, or restart the engine.")
            config = EngineConfig(device: nil)
        }
        let engine = Engine(options: options, config: config)
        engine.start()
        dispatchMain()
    default:
        fail("unknown command \(options.command); try --help")
    }
}
#endif

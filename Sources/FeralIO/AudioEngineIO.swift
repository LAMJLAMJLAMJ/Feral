#if os(macOS)
import CoreAudio
import FeralCore
import FeralCoreAudio
import FeralScene
import Foundation

/// Opens one Core Audio device for input and output, runs the render core's IOProc on it, and keeps
/// it open: if the device disappears, changes sample rate or changes its channels, the engine keeps
/// its state, closes the device and tries again every second until it is back.
///
/// Every method and callback runs on `queue`, the engine's control queue.
public final class AudioEngineIO {
    public enum State: Equatable {
        case stopped
        /// Waiting for the device to appear or to open; the string says why.
        case waiting(String)
        case running(device: String)
    }

    public private(set) var state: State = .stopped
    /// Faults since start: device lost, sample rate or channel changes, failed opens.
    public private(set) var faults = 0
    /// Times Core Audio reported the IOProc ran late (an overload, heard as a dropout).
    public private(set) var overloads = 0

    private let core: RenderCore
    private let queue: DispatchQueue
    private let log: (String) -> Void
    private var config: EngineConfig
    private var device: AudioDevice?
    private var io: OpaquePointer?
    private var procID: AudioDeviceIOProcID?
    private var retryTimer: DispatchSourceTimer?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var lastError: String?

    public init(core: RenderCore, config: EngineConfig, queue: DispatchQueue, log: @escaping (String) -> Void) {
        self.core = core
        self.config = config
        self.queue = queue
        self.log = log
    }

    deinit { close() }

    /// Buffers the IOProc skipped (wrong format or too large), since the device was last opened.
    public var skippedBuffers: UInt64 { io.map { feral_io_skipped_buffers($0) } ?? 0 }

    /// The device the engine has open, if any.
    public var openDevice: AudioDevice? { device }

    /// Opens the device, or keeps trying every second until it can.
    public func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard state == .stopped else { return }
        attemptOpen()
    }

    public func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        retryTimer?.cancel()
        retryTimer = nil
        close()
        state = .stopped
    }

    /// Applies new device settings by closing and reopening the device.
    public func reconfigure(_ newConfig: EngineConfig) {
        dispatchPrecondition(condition: .onQueue(queue))
        config = newConfig
        guard state != .stopped else { return }
        close()
        state = .waiting("reopening with new settings")
        attemptOpen()
    }

    // MARK: - Opening and closing

    private func attemptOpen() {
        do {
            try open()
            retryTimer?.cancel()
            retryTimer = nil
            lastError = nil
        } catch {
            close()
            let message = "\(error)"
            if message != lastError {
                // Log each new reason once, not every second.
                log("audio: cannot open the device yet: \(message). Retrying every second.")
                lastError = message
                faults += 1
            }
            state = .waiting(message)
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, case .waiting = self.state else { return }
            self.attemptOpen()
        }
        timer.resume()
        retryTimer = timer
    }

    private func open() throws {
        guard let query = config.device, !query.isEmpty else {
            throw ConfigError("no device is set; put its UID or name in engine.json (see `feral-engine devices`)")
        }
        let found = try AudioDevices.find(query)
        if config.refuseAggregateDevices && found.isAggregate { throw AudioIOError.aggregateDevice(found.name) }

        try AudioDevices.setSampleRate(config.sampleRate, on: found)
        try AudioDevices.setBufferFrames(config.bufferFrames, on: found)
        let frames = (try? AudioDevices.scalar(found.id, kAudioDevicePropertyBufferFrameSize) as UInt32).map { Int($0) }
        if let frames, frames != config.bufferFrames {
            log("audio: \(found.name) runs at \(frames) frames, not the \(config.bufferFrames) asked for")
        }
        for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput]
        where !AudioDevices.streamsAreFloat32(found.id, scope: scope) {
            throw AudioIOError.notFloat32(device: found.name)
        }

        // Re-read the device so the channel counts are the ones at the rate just set.
        let dev = try AudioDevices.device(id: found.id)
        let inputMap = Self.channelMap(count: config.inputs, first: config.firstInputChannel, available: dev.inputChannels)
        let outputMap = Self.channelMap(count: config.outputs, first: config.firstOutputChannel, available: dev.outputChannels)
        let connectedIn = inputMap.filter { $0 >= 0 }.count
        let connectedOut = outputMap.filter { $0 >= 0 }.count

        guard let io = inputMap.withUnsafeBufferPointer({ i in
            outputMap.withUnsafeBufferPointer { o in
                feral_io_create(core.pointer, i.baseAddress, Int32(i.count), o.baseAddress, Int32(o.count))
            }
        }) else { throw ConfigError("could not create the audio context") }
        self.io = io
        self.device = dev

        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcID(dev.id, feral_io_proc_pointer(), UnsafeMutableRawPointer(io), &proc),
                  "installing the audio callback on \(dev.name)")
        procID = proc
        addListeners(dev)
        try check(AudioDeviceStart(dev.id, proc), "starting \(dev.name)")

        state = .running(device: dev.name)
        log("audio: running on \(dev.name) (\(dev.transport), UID \(dev.uid)) at \(Int(config.sampleRate)) Hz, "
            + "\(frames ?? config.bufferFrames) frames; inputs \(connectedIn) of \(config.inputs) connected "
            + "(device has \(dev.inputChannels)), outputs \(connectedOut) of \(config.outputs) connected "
            + "(device has \(dev.outputChannels)); latency in \(dev.inputLatency), out \(dev.outputLatency) frames")
        if connectedOut < config.outputs {
            log("audio: \(config.outputs - connectedOut) engine output(s) have no device channel; "
                + "check outputs and firstOutputChannel in engine.json")
        }
    }

    private func close() {
        removeListeners()
        if let device, let procID {
            // AudioDeviceStop returns once the IOProc has finished its last call, so after it the
            // core's audio side is idle and the context can be freed.
            AudioDeviceStop(device.id, procID)
            AudioDeviceDestroyIOProcID(device.id, procID)
        }
        procID = nil
        core.audioDetached()
        if let io { feral_io_destroy(io) }
        io = nil
        device = nil
    }

    /// Engine channel k plays on (or reads from) device channel first - 1 + k, or -1 when the
    /// device has no such channel.
    public static func channelMap(count: Int, first: Int, available: Int) -> [Int32] {
        (0..<count).map { k in
            let c = first - 1 + k
            return c < available ? Int32(c) : -1
        }
    }

    // MARK: - Watching the device

    private func addListeners(_ dev: AudioDevice) {
        listen(dev.id, kAudioDevicePropertyDeviceIsAlive) { [weak self] in
            let alive: UInt32 = (try? AudioDevices.scalar(dev.id, kAudioDevicePropertyDeviceIsAlive)) ?? 0
            if alive == 0 { self?.lost("\(dev.name) disappeared") }
        }
        listen(dev.id, kAudioDevicePropertyNominalSampleRate) { [weak self] in
            guard let self else { return }
            let rate: Float64 = (try? AudioDevices.scalar(dev.id, kAudioDevicePropertyNominalSampleRate)) ?? 0
            if rate != self.config.sampleRate { self.lost("\(dev.name) changed to \(Int(rate)) Hz") }
        }
        for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
            listen(dev.id, kAudioDevicePropertyStreamConfiguration, scope) { [weak self] in
                self?.lost("\(dev.name) changed its channels")
            }
        }
        listen(dev.id, kAudioDeviceProcessorOverload) { [weak self] in
            self?.overloads += 1
        }
    }

    private func listen(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ action: @escaping () -> Void) {
        var addr = AudioDevices.address(selector, scope)
        let block: AudioObjectPropertyListenerBlock = { _, _ in action() }
        if AudioObjectAddPropertyListenerBlock(id, &addr, queue, block) == noErr {
            listeners.append((id, addr, block))
        }
    }

    private func removeListeners() {
        for (id, registered, block) in listeners {
            var addr = registered
            AudioObjectRemovePropertyListenerBlock(id, &addr, queue, block)
        }
        listeners.removeAll()
    }

    private func lost(_ reason: String) {
        guard case .running = state else { return }
        faults += 1
        log("audio: FAULT: \(reason). Holding the engine's state and reopening.")
        close()
        state = .waiting(reason)
        lastError = nil
        scheduleRetry()
    }
}

extension AudioDevices {
    /// Sets the device's buffer size in frames.
    public static func setBufferFrames(_ frames: Int, on device: AudioDevice) throws {
        var addr = address(kAudioDevicePropertyBufferFrameSize)
        var value = UInt32(frames)
        try check(AudioObjectSetPropertyData(device.id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value),
                  "setting \(device.name) to \(frames) frames")
    }

    /// Whether every stream on one side presents 32-bit float samples to the IOProc. A side with no
    /// streams counts as yes.
    static func streamsAreFloat32(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        guard let streams: [AudioStreamID] = try? array(id, kAudioDevicePropertyStreams, scope) else { return true }
        return streams.allSatisfy { stream in
            guard let format: AudioStreamBasicDescription = try? scalar(stream, kAudioStreamPropertyVirtualFormat)
            else { return false }
            return format.mFormatID == kAudioFormatLinearPCM
                && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
                && format.mBitsPerChannel == 32
        }
    }
}
#endif

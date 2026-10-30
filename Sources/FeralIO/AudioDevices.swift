#if os(macOS)
import CoreAudio
import Foundation

public enum AudioIOError: Error, CustomStringConvertible {
    case coreAudio(String, OSStatus)
    case deviceNotFound(String)
    case aggregateDevice(String)
    case sampleRateUnavailable(device: String, rate: Double)
    case notFloat32(device: String)

    public var description: String {
        switch self {
        case .coreAudio(let op, let status):
            return "Core Audio error \(status) (\(fourCC(status))) while \(op)"
        case .deviceNotFound(let name):
            return "No audio device matches '\(name)'. Run `feral-engine devices` to see the list."
        case .aggregateDevice(let name):
            return "\(name) is an aggregate device. Aggregates drift or resample between clocks, so the engine refuses them."
        case .sampleRateUnavailable(let device, let rate):
            return "\(device) does not support \(Int(rate)) Hz"
        case .notFloat32(let device):
            return "\(device) does not present 32-bit float streams to Core Audio"
        }
    }
}

/// Renders an OSStatus as its four-character code when it is one, for readable errors.
func fourCC(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((n >> $0) & 0xFF))) }
    return chars.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " ") } ? String(chars) : "\(status)"
}

func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw AudioIOError.coreAudio(operation, status) }
}

/// A Core Audio device: anything macOS can play to or record from, including USB, Thunderbolt and
/// PCIe interfaces, aggregate devices, and network audio drivers such as Dante Virtual Soundcard.
public struct AudioDevice: Identifiable, Hashable {
    public let id: AudioDeviceID
    /// Persistent identifier, stable across reboots and reconnection. Use it to remember a device.
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let outputChannels: Int
    public let sampleRate: Double
    public let availableSampleRates: [Double]
    public let transport: String
    /// Latency the driver reports, in frames, including the safety offset.
    public let inputLatency: Int
    public let outputLatency: Int

    public var isAggregate: Bool { transport == "Aggregate" }
}

public enum AudioDevices {
    /// Every audio device on the system.
    public static func all() throws -> [AudioDevice] {
        let ids: [AudioDeviceID] = try array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        return ids.compactMap { try? device(id: $0) }
    }

    public static func device(id: AudioDeviceID) throws -> AudioDevice {
        let rates: [AudioValueRange] = (try? array(id, kAudioDevicePropertyAvailableNominalSampleRates)) ?? []
        let common: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
        let available = common.filter { r in rates.contains { $0.mMinimum <= r && r <= $0.mMaximum } }
        return AudioDevice(
            id: id,
            uid: try string(id, kAudioDevicePropertyDeviceUID),
            name: try string(id, kAudioObjectPropertyName),
            inputChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
            outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput),
            sampleRate: (try? scalar(id, kAudioDevicePropertyNominalSampleRate) as Float64) ?? 0,
            availableSampleRates: available,
            transport: transportName((try? scalar(id, kAudioDevicePropertyTransportType) as UInt32) ?? 0),
            inputLatency: latency(id, scope: kAudioObjectPropertyScopeInput),
            outputLatency: latency(id, scope: kAudioObjectPropertyScopeOutput))
    }

    /// Finds a device by its list number (from 1), UID, or a case-insensitive part of its name.
    public static func find(_ query: String) throws -> AudioDevice {
        let devices = try all()
        if let n = Int(query), devices.indices.contains(n - 1) { return devices[n - 1] }
        if let d = devices.first(where: { $0.uid == query }) { return d }
        if let d = devices.first(where: { $0.name.localizedCaseInsensitiveContains(query) }) { return d }
        throw AudioIOError.deviceNotFound(query)
    }

    public static func defaultDevice(input: Bool) throws -> AudioDevice {
        let id: AudioDeviceID = try scalar(AudioObjectID(kAudioObjectSystemObject),
                                           input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        return try device(id: id)
    }

    /// Sets the device's sample rate and waits (up to 2 s) for the change to take effect.
    public static func setSampleRate(_ rate: Double, on device: AudioDevice) throws {
        var current: Float64 = (try? scalar(device.id, kAudioDevicePropertyNominalSampleRate)) ?? 0
        if current == rate { return }
        guard device.availableSampleRates.isEmpty || device.availableSampleRates.contains(rate) else {
            throw AudioIOError.sampleRateUnavailable(device: device.name, rate: rate)
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = Float64(rate)
        try check(AudioObjectSetPropertyData(device.id, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value),
                  "setting \(device.name) to \(Int(rate)) Hz")
        for _ in 0..<40 where current != rate {
            Thread.sleep(forTimeInterval: 0.05)
            current = (try? scalar(device.id, kAudioDevicePropertyNominalSampleRate)) ?? 0
        }
        if current != rate { throw AudioIOError.sampleRateUnavailable(device: device.name, rate: rate) }
    }

    // MARK: - Property helpers

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, pointer), "reading property \(fourCC(OSStatus(bitPattern: selector)))")
        return pointer.pointee
    }

    static func array<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [T] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size), "sizing property \(fourCC(OSStatus(bitPattern: selector)))")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { pointer.deallocate() }
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, pointer), "reading property \(fourCC(OSStatus(bitPattern: selector)))")
        return Array(UnsafeBufferPointer(start: pointer, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value), "reading a device name")
        return (value?.takeRetainedValue() as String?) ?? ""
    }

    static func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func latency(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        let device: UInt32 = (try? scalar(id, kAudioDevicePropertyLatency, scope)) ?? 0
        let safety: UInt32 = (try? scalar(id, kAudioDevicePropertySafetyOffset, scope)) ?? 0
        return Int(device + safety)
    }

    static func transportName(_ t: UInt32) -> String {
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypePCI: return "PCIe"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeAVB: return "AVB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "Display"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        default: return "Other"
        }
    }
}
#endif

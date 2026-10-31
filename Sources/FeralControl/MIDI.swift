import FeralScene
import Foundation

// MIDI in: a byte-stream parser (running status, system exclusive split across packets, real-time
// bytes in the middle of anything) and MIDI Show Control. Pure Swift, so it is tested on Linux too;
// MIDIInput.swift feeds it from Core MIDI on the Mac.

/// The MIDI messages the engine acts on. Channels are 1 to 16.
public enum MIDIMessage: Equatable {
    case noteOn(channel: Int, note: Int, velocity: Int)
    case controlChange(channel: Int, controller: Int, value: Int)
    /// Program 1 to 128, as consoles number them.
    case programChange(channel: Int, program: Int)
    case showControl(MSCMessage)
}

/// A MIDI Show Control message.
public struct MSCMessage: Equatable {
    /// 0 to 111, or 112 to 126 for groups, or 127 for everyone.
    public var deviceID: Int
    public var command: MSCCommand
    /// The cue number ("12.5"), when it has one.
    public var cue: String?
    public var list: String?

    public init(deviceID: Int, command: MSCCommand, cue: String? = nil, list: String? = nil) {
        self.deviceID = deviceID; self.command = command; self.cue = cue; self.list = list
    }

    static let codes: [UInt8: MSCCommand] = [
        0x01: .go, 0x02: .stop, 0x03: .resume, 0x04: .timedGo, 0x06: .set, 0x07: .fire, 0x08: .allOff,
        0x09: .restore, 0x0A: .reset, 0x0B: .goOff,
    ]

    /// Reads a system exclusive message (F0 ... F7, both included). None if it is not MSC, or not a
    /// command the engine knows.
    public static func parse(_ sysex: [UInt8]) -> MSCMessage? {
        // F0 7F <device> 02 <format> <command> <data> F7
        guard sysex.count >= 7, sysex[0] == 0xF0, sysex[1] == 0x7F, sysex[3] == 0x02, sysex.last == 0xF7 else { return nil }
        guard let command = codes[sysex[5]] else { return nil }
        var data = Array(sysex[6..<(sysex.count - 1)])
        // TIMED_GO carries a 5-byte time before its cue number; the engine runs cues on arrival.
        if command == .timedGo { data = Array(data.dropFirst(5)) }
        // SET carries a control number and value, not a cue.
        if command == .set || command == .fire || command == .allOff || command == .restore || command == .reset {
            return MSCMessage(deviceID: Int(sysex[2]), command: command)
        }
        // The cue number, list and path, each ASCII digits and "." ended by 00.
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { field -> String? in
            let text = String(decoding: field.filter { ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E }, as: UTF8.self)
            return text.isEmpty ? nil : text
        }
        return MSCMessage(deviceID: Int(sysex[2]), command: command, cue: fields.first ?? nil,
                          list: fields.count > 1 ? fields[1] : nil)
    }

    /// The system exclusive bytes (sound, general).
    public var bytes: [UInt8] {
        let code = MSCMessage.codes.first { $0.value == command }!.key
        var b: [UInt8] = [0xF0, 0x7F, UInt8(clamping: deviceID), 0x02, 0x10, code]
        if command == .timedGo { b += [0, 0, 0, 0, 0] }
        if let cue {
            b += Array(cue.utf8)
            if let list { b += [0] + Array(list.utf8) }
        }
        return b + [0xF7]
    }
}

/// Turns MIDI bytes, as they arrive, into messages. One per MIDI source, since running status and an
/// unfinished system exclusive message belong to the stream they came on.
public struct MIDIParser {
    /// A system exclusive message longer than this is dropped.
    public static let maxSysex = 1024
    private var status: UInt8 = 0
    private var data: [UInt8] = []
    private var sysex: [UInt8]?

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [MIDIMessage] {
        var out: [MIDIMessage] = []
        for b in bytes {
            if b >= 0xF8 { continue } // real time (clock, start, active sensing): may come anywhere
            if b == 0xF0 {
                sysex = [b]
                status = 0
                continue
            }
            if b == 0xF7 {
                if var s = sysex {
                    s.append(b)
                    if let m = MSCMessage.parse(s) { out.append(.showControl(m)) }
                }
                sysex = nil
                continue
            }
            if var s = sysex {
                if b < 0x80 {
                    s.append(b)
                    sysex = s.count > MIDIParser.maxSysex ? nil : s
                    continue
                }
                sysex = nil // a status byte ends an unfinished system exclusive message
            }
            if b >= 0x80 {
                // System common (F1 to F6) cancels running status; channel messages set it.
                status = b < 0xF0 ? b : 0
                data = []
                continue
            }
            guard status != 0 else { continue } // data with no status to go with
            data.append(b)
            let kind = status & 0xF0
            let channel = Int(status & 0x0F) + 1
            let needed = (kind == 0xC0 || kind == 0xD0) ? 1 : 2
            guard data.count == needed else { continue }
            switch kind {
            case 0x90 where data[1] > 0: out.append(.noteOn(channel: channel, note: Int(data[0]), velocity: Int(data[1])))
            case 0xB0: out.append(.controlChange(channel: channel, controller: Int(data[0]), value: Int(data[1])))
            case 0xC0: out.append(.programChange(channel: channel, program: Int(data[0]) + 1))
            default: break
            }
            data = []
        }
        return out
    }
}

extension MIDIMessage: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noteOn(let c, let n, let v): return "note \(n) velocity \(v) on channel \(c)"
        case .controlChange(let c, let cc, let v): return "CC \(cc) = \(v) on channel \(c)"
        case .programChange(let c, let p): return "program change \(p) on channel \(c)"
        case .showControl(let m): return "MSC \(m.command.rawValue)" + (m.cue.map { " cue \($0)" } ?? "") + " (device \(m.deviceID))"
        }
    }

    /// The bytes, for sending.
    public var bytes: [UInt8] {
        func st(_ kind: UInt8, _ c: Int) -> UInt8 { kind | UInt8(clamping: max(1, min(c, 16)) - 1) }
        func d(_ v: Int) -> UInt8 { UInt8(clamping: max(0, min(v, 127))) }
        switch self {
        case .noteOn(let c, let n, let v): return [st(0x90, c), d(n), d(v)]
        case .controlChange(let c, let cc, let v): return [st(0xB0, c), d(cc), d(v)]
        case .programChange(let c, let p): return [st(0xC0, c), d(p - 1)]
        case .showControl(let m): return m.bytes
        }
    }
}

import Foundation

// Open Sound Control 1.0 packets: messages and bundles, read and written. Reading never traps: any
// packet that is cut short, misaligned or nested too deep is refused with an error, so malformed OSC
// from the network can never crash or stall the engine.

/// One OSC argument.
public enum OSCValue: Equatable {
    case int(Int32)
    case float(Float)
    case string(String)
    case blob(Data)
    case int64(Int64)
    case double(Double)
    case bool(Bool)
    /// Nil (N) and Impulse (I).
    case none

    /// The value as a number, if it is one (true is 1).
    public var number: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .float(let v): return Double(v)
        case .int64(let v): return Double(v)
        case .double(let v): return v
        case .bool(let v): return v ? 1 : 0
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        case .blob, .none: return nil
        }
    }

    /// The value as text: "5" for a whole number however it came, "5.5", or the string.
    public var text: String? {
        switch self {
        case .string(let s): return s
        case .blob, .none: return nil
        default:
            guard let n = number else { return nil }
            if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
            return String(n)
        }
    }
}

public struct OSCMessage: Equatable {
    public var address: String
    public var arguments: [OSCValue]

    public init(_ address: String, _ arguments: [OSCValue] = []) {
        self.address = address; self.arguments = arguments
    }

    /// The address split at "/": "/feral/cue/5/go" is ["feral", "cue", "5", "go"].
    public var parts: [Substring] { address.split(separator: "/", omittingEmptySubsequences: true) }

    /// "/feral/source/1/xyz 1 2 3".
    public var description: String {
        ([address] + arguments.map { a -> String in
            switch a {
            case .string(let s): return "\"\(s)\""
            case .blob(let d): return "<\(d.count) bytes>"
            case .none: return "nil"
            case .bool(let b): return b ? "true" : "false"
            default: return a.text ?? "?"
            }
        }).joined(separator: " ")
    }
}

public struct OSCError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum OSC {
    /// Bundles inside bundles deeper than this are refused.
    public static let maxDepth = 8

    /// Every message in a packet, in order, bundles opened (their time tags are ignored: everything
    /// happens on arrival).
    public static func messages(in packet: Data) throws -> [OSCMessage] {
        var out: [OSCMessage] = []
        try read(Array(packet), depth: 0, into: &out)
        return out
    }

    private static func read(_ bytes: [UInt8], depth: Int, into out: inout [OSCMessage]) throws {
        guard depth <= maxDepth else { throw OSCError("bundles nested more than \(maxDepth) deep") }
        guard bytes.count >= 4 else { throw OSCError("a packet shorter than 4 bytes") }
        guard bytes.count % 4 == 0 else { throw OSCError("a packet whose size is not a multiple of 4") }
        if bytes[0] == UInt8(ascii: "#") {
            var r = Reader(bytes)
            guard try r.string() == "#bundle" else { throw OSCError("a packet starting with # that is not a bundle") }
            _ = try r.take(8) // time tag
            while !r.isAtEnd {
                let size = try r.int32()
                guard size >= 0, size % 4 == 0 else { throw OSCError("a bundle element of size \(size)") }
                let element = try r.take(Int(size))
                guard !element.isEmpty else { continue }
                try read(element, depth: depth + 1, into: &out)
            }
        } else {
            out.append(try message(bytes))
        }
    }

    private static func message(_ bytes: [UInt8]) throws -> OSCMessage {
        var r = Reader(bytes)
        let address = try r.string()
        guard address.hasPrefix("/") else { throw OSCError("an address that does not start with /") }
        if r.isAtEnd { return OSCMessage(address) } // no type tag string: an old-style message with no arguments
        let tags = try r.string()
        guard tags.first == "," else { throw OSCError("a type tag string that does not start with a comma") }
        var args: [OSCValue] = []
        for tag in tags.utf8.dropFirst() {
            switch tag {
            case UInt8(ascii: "i"): args.append(.int(try r.int32()))
            case UInt8(ascii: "f"): args.append(.float(Float(bitPattern: UInt32(bitPattern: try r.int32()))))
            case UInt8(ascii: "s"), UInt8(ascii: "S"): args.append(.string(try r.string()))
            case UInt8(ascii: "b"):
                let n = try r.int32()
                guard n >= 0 else { throw OSCError("a blob of size \(n)") }
                let data = try r.take(Int(n))
                _ = try r.take((4 - Int(n) % 4) % 4)
                args.append(.blob(Data(data)))
            case UInt8(ascii: "h"): args.append(.int64(try r.int64()))
            case UInt8(ascii: "d"): args.append(.double(Double(bitPattern: UInt64(bitPattern: try r.int64()))))
            case UInt8(ascii: "t"): args.append(.int64(try r.int64()))
            case UInt8(ascii: "c"), UInt8(ascii: "r"), UInt8(ascii: "m"): args.append(.int(try r.int32()))
            case UInt8(ascii: "T"): args.append(.bool(true))
            case UInt8(ascii: "F"): args.append(.bool(false))
            case UInt8(ascii: "N"), UInt8(ascii: "I"): args.append(.none)
            case UInt8(ascii: "["), UInt8(ascii: "]"): break // arrays: their contents are read as plain arguments
            default: throw OSCError("an argument of unknown type \(Character(Unicode.Scalar(tag)))")
            }
        }
        return OSCMessage(address, args)
    }

    /// A message as a packet.
    public static func encode(_ m: OSCMessage) -> Data {
        var w = Writer()
        w.string(m.address)
        var tags = ","
        for a in m.arguments {
            switch a {
            case .int: tags += "i"
            case .float: tags += "f"
            case .string: tags += "s"
            case .blob: tags += "b"
            case .int64: tags += "h"
            case .double: tags += "d"
            case .bool(let b): tags += b ? "T" : "F"
            case .none: tags += "N"
            }
        }
        w.string(tags)
        for a in m.arguments {
            switch a {
            case .int(let v): w.int32(v)
            case .float(let v): w.int32(Int32(bitPattern: v.bitPattern))
            case .string(let s): w.string(s)
            case .blob(let d):
                w.int32(Int32(d.count))
                w.bytes += d
                w.pad()
            case .int64(let v): w.int64(v)
            case .double(let v): w.int64(Int64(bitPattern: v.bitPattern))
            case .bool, .none: break
            }
        }
        return Data(w.bytes)
    }

    /// Messages as one bundle, to be run at once.
    public static func bundle(_ messages: [OSCMessage]) -> Data {
        var w = Writer()
        w.string("#bundle")
        w.int64(1) // "immediately"
        for m in messages {
            let data = encode(m)
            w.int32(Int32(data.count))
            w.bytes += data
        }
        return Data(w.bytes)
    }

    private struct Reader {
        let bytes: [UInt8]
        var at = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool { at >= bytes.count }

        mutating func take(_ n: Int) throws -> [UInt8] {
            guard n >= 0, n <= bytes.count - at else { throw OSCError("a packet cut short") }
            defer { at += n }
            return Array(bytes[at..<at + n])
        }

        mutating func int32() throws -> Int32 {
            let b = try take(4)
            return Int32(bitPattern: UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        }

        mutating func int64() throws -> Int64 {
            let hi = UInt64(UInt32(bitPattern: try int32())), lo = UInt64(UInt32(bitPattern: try int32()))
            return Int64(bitPattern: hi << 32 | lo)
        }

        /// A null-terminated string padded to 4 bytes.
        mutating func string() throws -> String {
            guard let end = bytes[at...].firstIndex(of: 0) else { throw OSCError("a string with no end") }
            let s = String(decoding: bytes[at..<end], as: UTF8.self)
            let padded = (end - at) / 4 * 4 + 4
            _ = try take(padded)
            return s
        }
    }

    private struct Writer {
        var bytes: [UInt8] = []

        mutating func pad() { while bytes.count % 4 != 0 { bytes.append(0) } }

        mutating func string(_ s: String) {
            bytes += Array(s.utf8).filter { $0 != 0 }
            bytes.append(0)
            pad()
        }

        mutating func int32(_ v: Int32) {
            let u = UInt32(bitPattern: v)
            bytes += [UInt8(u >> 24), UInt8(u >> 16 & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u & 0xFF)]
        }

        mutating func int64(_ v: Int64) {
            let u = UInt64(bitPattern: v)
            int32(Int32(bitPattern: UInt32(u >> 32)))
            int32(Int32(bitPattern: UInt32(u & 0xFFFF_FFFF)))
        }
    }
}

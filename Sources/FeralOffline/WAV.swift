import FeralScene
import Foundation

/// A multichannel WAV file in memory. Reads 16, 24 and 32-bit integer and 32 and 64-bit float
/// files (plain or WAVE_FORMAT_EXTENSIBLE); writes 32-bit float.
public struct WAV: Equatable {
    public var sampleRate: Double
    /// One array per channel, all the same length.
    public var channels: [[Float]]

    public init(sampleRate: Double, channels: [[Float]]) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public var frames: Int { channels.first?.count ?? 0 }

    public static func read(_ url: URL) throws -> WAV {
        try decode(Data(contentsOf: url), name: url.lastPathComponent)
    }

    public func write(to url: URL) throws {
        try encode().write(to: url, options: .atomic)
    }

    public static func decode(_ data: Data, name: String = "file") throws -> WAV {
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        func tag(_ i: Int) -> String { String(decoding: bytes[i..<i + 4], as: UTF8.self) }
        guard bytes.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { throw ConfigError("\(name) is not a WAV file") }

        var format: (code: Int, channels: Int, rate: Int, bits: Int)?
        var body: Range<Int>?
        var i = 12
        while i + 8 <= bytes.count {
            let size = u32(i + 4), start = i + 8
            let end = min(start + size, bytes.count)
            switch tag(i) {
            case "fmt ":
                guard size >= 16 else { throw ConfigError("\(name): format chunk too short") }
                var code = u16(start)
                if code == 0xFFFE && size >= 26 { code = u16(start + 24) } // the sub-format's first two bytes
                format = (code, u16(start + 2), u32(start + 4), u16(start + 14))
            case "data":
                body = start..<end
            default:
                break
            }
            i = start + size + (size & 1)
        }
        guard let f = format, let body else { throw ConfigError("\(name): no format or data chunk") }
        guard f.channels > 0 else { throw ConfigError("\(name): no channels") }
        let width = f.bits / 8
        guard [1, 3].contains(f.code), (f.code == 1 && [16, 24, 32].contains(f.bits)) || (f.code == 3 && [32, 64].contains(f.bits)) else {
            throw ConfigError("\(name): \(f.bits)-bit \(f.code == 3 ? "float" : "format \(f.code)") samples are not supported")
        }
        let frames = body.count / (width * f.channels)
        var channels = [[Float]](repeating: [Float](repeating: 0, count: frames), count: f.channels)
        bytes.withUnsafeBytes { raw in
            for n in 0..<frames {
                for c in 0..<f.channels {
                    let at = body.lowerBound + (n * f.channels + c) * width
                    let v: Float
                    switch (f.code, f.bits) {
                    case (1, 16): v = Float(raw.loadUnaligned(fromByteOffset: at, as: Int16.self)) / 32768
                    case (1, 24):
                        let x = Int32(bitPattern: UInt32(raw[at]) << 8 | UInt32(raw[at + 1]) << 16 | UInt32(raw[at + 2]) << 24) >> 8
                        v = Float(x) / 8_388_608
                    case (1, _): v = Float(Double(raw.loadUnaligned(fromByteOffset: at, as: Int32.self)) / 2_147_483_648)
                    case (3, 32): v = Float(bitPattern: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))
                    default: v = Float(Double(bitPattern: raw.loadUnaligned(fromByteOffset: at, as: UInt64.self)))
                    }
                    channels[c][n] = v
                }
            }
        }
        return WAV(sampleRate: Double(f.rate), channels: channels)
    }

    /// 32-bit float, WAVE_FORMAT_EXTENSIBLE (needed for more than two channels).
    public func encode() -> Data {
        let count = channels.count, frames = self.frames
        var d = Data()
        func put32(_ v: Int) { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).littleEndian) { d.append(contentsOf: $0) } }
        func put16(_ v: Int) { withUnsafeBytes(of: UInt16(truncatingIfNeeded: v).littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = frames * count * 4
        d.append(contentsOf: Array("RIFF".utf8)); put32(4 + 8 + 40 + 8 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); put32(40)
        put16(0xFFFE); put16(count); put32(Int(sampleRate)); put32(Int(sampleRate) * count * 4); put16(count * 4); put16(32)
        put16(22); put16(32); put32(0) // extension size, valid bits, channel mask (none: discrete channels)
        // KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
        d.append(contentsOf: [0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        d.append(contentsOf: Array("data".utf8)); put32(dataBytes)
        var interleaved = [UInt32](repeating: 0, count: frames * count)
        for c in 0..<count { for n in 0..<frames { interleaved[n * count + c] = channels[c][n].bitPattern.littleEndian } }
        interleaved.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}

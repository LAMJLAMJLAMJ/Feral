import FeralOffline
import FeralScene
import Foundation
import XCTest

final class KnownAnswerTests: XCTestCase {
    /// Every known answer feral-cli check prints must pass.
    func testKnownAnswers() {
        let results = KnownAnswers.run()
        XCTAssertGreaterThanOrEqual(results.count, 16)
        for r in results { XCTAssertTrue(r.passed, "\(r.name): \(r.detail)") }
    }
}

final class WAVTests: XCTestCase {
    func testFloatRoundTrip() throws {
        let wav = WAV(sampleRate: 48_000, channels: [[0, 0.5, -1, 0.25], [1, -0.5, 0, 0.125], [0.1, 0.2, 0.3, 0.4]])
        let back = try WAV.decode(wav.encode())
        XCTAssertEqual(back, wav)
    }

    func testReads16And24BitPCM() throws {
        func pcm(bits: Int, samples: [Int]) -> Data {
            var d = Data()
            func put32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
            func put16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
            let width = bits / 8
            d.append(contentsOf: Array("RIFF".utf8)); put32(36 + samples.count * width)
            d.append(contentsOf: Array("WAVEfmt ".utf8)); put32(16)
            put16(1); put16(1); put32(44_100); put32(44_100 * width); put16(width); put16(bits)
            d.append(contentsOf: Array("data".utf8)); put32(samples.count * width)
            for s in samples { for b in 0..<width { d.append(UInt8(truncatingIfNeeded: s >> (8 * b))) } }
            return d
        }
        let w16 = try WAV.decode(pcm(bits: 16, samples: [0, 16384, -32768]))
        XCTAssertEqual(w16.sampleRate, 44_100)
        XCTAssertEqual(w16.channels, [[0, 0.5, -1]])
        let w24 = try WAV.decode(pcm(bits: 24, samples: [0, 4_194_304, -8_388_608]))
        XCTAssertEqual(w24.channels, [[0, 0.5, -1]])
        XCTAssertThrowsError(try WAV.decode(Data("not a wav file".utf8)))
    }
}

final class OfflineRendererTests: XCTestCase {
    static var example: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("examples/stage-test.json")
    }

    /// The example layout loads, and an impulse on the test source reaches the front line, fills,
    /// delays, overheads and subs, with the nearest main speaker after the 10 ms precedence only.
    func testExampleLayoutImpulse() throws {
        var config = try EngineConfig.load(from: Self.example)
        config.testSignal = .off
        config.testMotion = nil
        let renderer = try OfflineRenderer(config: config)
        let arrivals = renderer.impulse(input: 1, seconds: 0.3)
        let outputs = Set(arrivals.map(\.output))
        XCTAssertTrue(outputs.isSuperset(of: Set(1...16)), "every Delay group speaker plays: \(outputs.sorted())")
        XCTAssertTrue(outputs.contains(25) && outputs.contains(26), "the subs get the LFE send")
        XCTAssertTrue(outputs.contains { (17...24).contains($0) }, "an overhead plays")
        let first = arrivals.filter { $0.output <= 16 }.map(\.milliseconds).min() ?? 0
        XCTAssertEqual(first, 10, accuracy: 0.05, "the nearest speaker arrives after the precedence only")
        // Front fill 2 at [-2, 1, 0.5] is nearest the source at [0, 2, 1.6]: 6 dB trim, so -6 dB.
        let fill = try XCTUnwrap(arrivals.first { $0.output == 10 })
        XCTAssertEqual(fill.milliseconds, 10, accuracy: 0.05)
    }

    /// The test motion moves the source while rendering, and the delays follow without a jump in level.
    func testExampleWithMotionRenders() throws {
        var config = try EngineConfig.load(from: Self.example)
        config.testMotion?.seconds = 2
        let renderer = try OfflineRenderer(config: config)
        let y = renderer.render(length: 48_000, input: [])
        XCTAssertEqual(y.count, 26)
        let peak = y.map { $0.map { abs($0) }.max() ?? 0 }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.01, "the pink test signal plays")
        XCTAssertLessThan(peak, 0.9, "limiters at -1 dB and the -20 dB signal keep it well below full scale")
        // No click: no output jumps by more than the pink noise itself could between two samples.
        for channel in y { for n in 1..<channel.count { XCTAssertLessThan(abs(channel[n] - channel[n - 1]), 0.5) } }
    }
}

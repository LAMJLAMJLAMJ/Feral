import FeralScene
import Foundation
import XCTest

final class RoutingTests: XCTestCase {
    func testNoRoutesIsAPassthrough() throws {
        let r = try Routing(routes: [], inputs: 128, outputs: 128)
        XCTAssertEqual(r.gains.filter { $0 != 0 }.count, 128)
        for n in 1...128 { XCTAssertEqual(r.gain(input: n, output: n), 1) }
        XCTAssertEqual(r.gain(input: 1, output: 2), 0)

        // With fewer inputs than outputs, the extra outputs stay silent.
        let narrow = try Routing(routes: [], inputs: 2, outputs: 4)
        XCTAssertEqual(narrow.gains.filter { $0 != 0 }.count, 2)
    }

    func testRangesPairUpInOrder() throws {
        let r = try Routing(routes: [Route(inputs: "1-64", outputs: "65-128")], inputs: 64, outputs: 128)
        XCTAssertEqual(r.gain(input: 1, output: 65), 1)
        XCTAssertEqual(r.gain(input: 64, output: 128), 1)
        XCTAssertEqual(r.gain(input: 1, output: 1), 0)
        XCTAssertEqual(r.gains.filter { $0 != 0 }.count, 64)
    }

    func testOneInputFeedsManyOutputsAndManySumIntoOne() throws {
        let r = try Routing(routes: [
            Route(inputs: "1", outputs: "1-128", gainDB: -20),
            Route(inputs: "2-4", outputs: "5"),
        ], inputs: 4, outputs: 128)
        for o in 1...128 where o != 5 { XCTAssertEqual(r.gain(input: 1, output: o), 0.1, accuracy: 1e-6) }
        XCTAssertEqual(r.gain(input: 1, output: 5), 0.1, accuracy: 1e-6)
        for i in 2...4 { XCTAssertEqual(r.gain(input: i, output: 5), 1) }
    }

    func testLaterRoutesReplaceEarlierOnes() throws {
        let r = try Routing(routes: [
            Route(inputs: "1-8", outputs: "1-8"),
            Route(inputs: "3", outputs: "3", gainDB: -200), // muted
        ], inputs: 8, outputs: 8)
        XCTAssertEqual(r.gain(input: 3, output: 3), 0)
        XCTAssertEqual(r.gain(input: 4, output: 4), 1)
    }

    func testBadRoutesAreRefused() {
        XCTAssertThrowsError(try Routing(routes: [Route(inputs: "1-3", outputs: "1-2")], inputs: 4, outputs: 4))
        XCTAssertThrowsError(try Routing(routes: [Route(inputs: "0", outputs: "1")], inputs: 4, outputs: 4))
        XCTAssertThrowsError(try Routing(routes: [Route(inputs: "1", outputs: "5")], inputs: 4, outputs: 4))
        XCTAssertThrowsError(try Routing(routes: [Route(inputs: "4-2", outputs: "1")], inputs: 4, outputs: 4))
        XCTAssertThrowsError(try Routing(routes: [Route(inputs: "a", outputs: "1")], inputs: 4, outputs: 4))
    }
}

final class EngineConfigTests: XCTestCase {
    func testDefaultsAre128By128At48kAnd64Frames() throws {
        let c = try JSONDecoder().decode(EngineConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(c, EngineConfig())
        XCTAssertNil(c.device)
        XCTAssertEqual(c.sampleRate, 48_000)
        XCTAssertEqual(c.bufferFrames, 64)
        XCTAssertEqual(c.inputs, 128)
        XCTAssertEqual(c.outputs, 128)
        XCTAssertTrue(c.refuseAggregateDevices)
        XCTAssertNoThrow(try c.validate())
    }

    /// The README's example for testing every output of an RME MADIface XT from one input.
    func testMADIfaceExample() throws {
        let json = """
        {
          "device": "MADIface XT",
          "bufferFrames": 128,
          "inputs": 1,
          "outputs": 128,
          "firstInputChannel": 1,
          "firstOutputChannel": 1,
          "routes": [ { "inputs": 1, "outputs": "1-128", "gainDB": -20 } ]
        }
        """
        let c = try JSONDecoder().decode(EngineConfig.self, from: Data(json.utf8))
        XCTAssertNoThrow(try c.validate())
        XCTAssertEqual(c.device, "MADIface XT")
        XCTAssertEqual(c.routes, [Route(inputs: "1", outputs: "1-128", gainDB: -20)])
        let r = try Routing(routes: c.routes, inputs: c.inputs, outputs: c.outputs)
        XCTAssertEqual(r.gains.filter { $0 != 0 }.count, 128)
    }

    func testSaveAndLoad() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("engine.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let c = EngineConfig(device: "UID-1", bufferFrames: 128, inputs: 64, outputs: 96, firstOutputChannel: 65,
                             routes: [Route(inputs: "1-64", outputs: "1-64", gainDB: -3)])
        try c.save(to: url)
        XCTAssertEqual(try EngineConfig.load(from: url), c)
    }

    func testValidation() {
        XCTAssertThrowsError(try EngineConfig(inputs: 300).validate())
        XCTAssertThrowsError(try EngineConfig(sampleRate: 96_000).validate())
        XCTAssertThrowsError(try EngineConfig(bufferFrames: 8).validate())
        XCTAssertThrowsError(try EngineConfig(firstOutputChannel: 0).validate())
        XCTAssertThrowsError(try EngineConfig(inputs: 2, routes: [Route(inputs: "3", outputs: "1")]).validate())
    }
}

import FeralScene
import Foundation
import XCTest

final class SpatialConfigTests: XCTestCase {
    let layout = """
    {
      "inputs": 2, "outputs": 6,
      "speakers": [
        { "output": 1, "name": "L", "position": [-4, 0, 5] },
        { "output": 2, "name": "R", "position": [4, 0, 5], "delayMS": 1.5, "trimDB": -3, "invert": true },
        { "output": 3, "position": [-4, 10, 5] },
        { "output": 4, "position": [4, 10, 5], "eq": [{ "type": "peak", "hz": 2000, "gainDB": -4 }], "limiterDB": -2 },
        { "output": 5, "position": [0, 5, 8] },
        { "output": 6, "position": [0, 0, 0] }
      ],
      "groups": [
        { "name": "Main", "renderer": "delay", "speakers": "1-2, 3-4" },
        { "name": "Top", "renderer": "dbap", "speakers": 5 }
      ],
      "lfeOutputs": "6",
      "sources": [
        { "input": 1, "position": [0, 2, 1.6] },
        { "input": 2, "name": "Vox", "position": [-2, 1], "groups": ["Main"], "lfeDB": -6 }
      ]
    }
    """

    func config(_ json: String) throws -> EngineConfig {
        let c = try JSONDecoder().decode(EngineConfig.self, from: Data(json.utf8))
        try c.validate()
        return c
    }

    func testLayoutParsesWithDefaults() throws {
        let c = try config(layout)
        XCTAssertTrue(c.isSpatial)
        XCTAssertEqual(c.speakers.count, 6)
        XCTAssertEqual(c.speakers[1].trimDB, -3)
        XCTAssertTrue(c.speakers[1].invert)
        XCTAssertEqual(c.groups[0].precedenceMS, 10)
        XCTAssertEqual(c.groups[1].speakers, "5")
        XCTAssertEqual(c.sources[1].position, Position(-2, 1, 0), "z defaults to 0")
        XCTAssertNil(c.sources[0].groups, "no groups means every group")
        XCTAssertEqual(c.sources[1].groups, ["Main": 0])
        XCTAssertEqual(c.delayMotion, DelayMotion(glideRate: 0.005, jump: 240, crossfade: 1440))
        XCTAssertEqual(c.groupCrossfadeFrames, 2400)
    }

    func testTapsFollowTheGroupsAndSends() throws {
        let r = try SpatialRenderer(config: try config(layout))
        let all = r.allTaps
        // Source 1: four Delay speakers and the DBAP one. Source 2: Main only, plus the LFE send.
        XCTAssertEqual(all[0].count, 5)
        XCTAssertEqual(Set(all[0].map(\.group)), ["Main", "Top"])
        XCTAssertEqual(all[1].filter { $0.group == "Main" }.count, 4)
        let lfe = try XCTUnwrap(all[1].first { $0.group == "LFE" })
        XCTAssertEqual(lfe.output, 5)
        XCTAssertEqual(lfe.gain, 0.501, accuracy: 0.001)
        XCTAssertEqual(all[0].first { $0.group == "Top" }?.gain ?? 0, 1, accuracy: 1e-6, "one DBAP speaker takes it all")
        // The nearest Delay speaker plays after the precedence only.
        XCTAssertEqual(all[0].filter(\.delayed).map(\.delay).min() ?? 0, 0.010, accuracy: 1e-9)
        let state = r.makeState()
        XCTAssertEqual(state.tapCount, 10)
    }

    func testMovingASourceRecomputesOnlyIt() throws {
        let r = try SpatialRenderer(config: try config(layout))
        let before = r.allTaps
        r.move(source: 0, to: Position(0, 9, 1.6))
        XCTAssertEqual(r.allTaps[1], before[1])
        XCTAssertNotEqual(r.allTaps[0], before[0])
        // Now the rear pair is nearest.
        let nearest = r.allTaps[0].filter(\.delayed).min { $0.delay < $1.delay }
        XCTAssertTrue([2, 3].contains(nearest?.output ?? -1))
    }

    func testSpeakerProcessing() throws {
        let c = try config(layout)
        let r = SpatialRenderer.outputParams(c.speakers[1], sampleRate: 48_000)
        XCTAssertEqual(r.delay, 72)
        XCTAssertEqual(r.gain, -0.7079, accuracy: 1e-4)
        let eq = SpatialRenderer.outputParams(c.speakers[3], sampleRate: 48_000)
        XCTAssertEqual(eq.eq.count, 1)
        XCTAssertEqual(eq.eq[0].responseDB(at: 2000, sampleRate: 48_000), -4, accuracy: 1e-3)
        XCTAssertEqual(eq.limiterThreshold, 0.7943, accuracy: 1e-4)
    }

    func testBadLayoutsAreRefused() throws {
        func refused(_ change: (inout EngineConfig) -> Void, _ why: String, line: UInt = #line) throws {
            var c = try config(layout)
            change(&c)
            XCTAssertThrowsError(try c.validate(), why, line: line)
        }
        try refused({ $0.groups[1].speakers = "5-6, 7" }, "output 7 is outside the engine")
        try refused({ $0.speakers.remove(at: 4) }, "a group output with no speaker")
        try refused({ $0.groups.append(GroupConfig(name: "Fill", renderer: .delay, speakers: "1")) }, "a speaker in two Delay groups")
        try refused({ $0.groups.append(GroupConfig(name: "Main", renderer: .dbap, speakers: "5")) }, "two groups with one name")
        try refused({ $0.sources[0].groups = ["Nowhere": 0] }, "a send to a missing group")
        try refused({ $0.sources[1].input = 1 }, "two sources on one input")
        try refused({ $0.speakers[0].output = 2 }, "two speakers on one output")
        try refused({ $0.groups[1] = GroupConfig(name: "Top", renderer: .vbap, speakers: "5") }, "VBAP needs two speakers")
        try refused({ $0.testMotion = TestMotion(source: 9) }, "test motion of a missing source")
        try refused({ $0.lfeOutputs = nil }, "an LFE send with nowhere to go")
    }

    func testChannelLists() throws {
        XCTAssertEqual(try Routing.channelList("1-3, 7, 10-11", limit: 16, side: "output"), [1, 2, 3, 7, 10, 11])
        XCTAssertThrowsError(try Routing.channelList("1-3, 17", limit: 16, side: "output"))
        XCTAssertThrowsError(try Routing.channelList("", limit: 16, side: "output"))
    }

    func testTestMotionPath() {
        let circle = TestMotion(source: 1, center: Position(0, 5, 1.6), radius: 5, seconds: 20)
        XCTAssertEqual(circle.position(at: 0).y, 0, accuracy: 1e-9, "starts at the front of the circle")
        XCTAssertEqual(circle.position(at: 5).x, 5, accuracy: 1e-9, "a quarter turn later, stage right")
        XCTAssertEqual(circle.position(at: 20).y, 0, accuracy: 1e-9)
        let line = TestMotion(source: 1, shape: .line, from: Position(-4, 0, 0), to: Position(4, 0, 0), seconds: 10)
        XCTAssertEqual(line.position(at: 2.5).x, 0, accuracy: 1e-9)
        XCTAssertEqual(line.position(at: 5).x, 4, accuracy: 1e-9)
        XCTAssertEqual(line.position(at: 7.5).x, 0, accuracy: 1e-9)
    }
}

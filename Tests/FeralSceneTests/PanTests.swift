import FeralCore
import FeralScene
import XCTest

/// The Pan renderer (a console pan pot across a row) and the LFE group's algorithms.
final class PanTests: XCTestCase {
    private let lcr = [feral_point(x: -4, y: 0, z: 5), feral_point(x: 0, y: 0, z: 5), feral_point(x: 4, y: 0, z: 5)]
    private let axis = Position(1, 0, 0)

    private func gains(_ x: Double, law: Double = 3) -> [Double] {
        SpatialRenderer.panGains(speakers: lcr, at: feral_point(x: x, y: 5, z: 1.6), axis: axis, lawDB: law)
    }

    func testOnASpeakerOnlyItPlays() {
        XCTAssertEqual(gains(0), [0, 1, 0])
        XCTAssertEqual(gains(-4), [1, 0, 0])
        XCTAssertEqual(gains(-9), [1, 0, 0], "past the left end: the end speaker")
        XCTAssertEqual(gains(9), [0, 0, 1])
    }

    func testPanLawAtHalfway() {
        let constantPower = gains(2)
        XCTAssertEqual(constantPower[1], 0.7071, accuracy: 1e-3)
        XCTAssertEqual(constantPower[2], 0.7071, accuracy: 1e-3)
        XCTAssertEqual(constantPower[0], 0)
        let linear = gains(-2, law: 6)
        XCTAssertEqual(linear[0], 0.5, accuracy: 1e-3)
        XCTAssertEqual(linear[1], 0.5, accuracy: 1e-3)
        // Constant power keeps the power the same all the way across.
        for x in stride(from: -4.0, through: 4.0, by: 0.5) {
            XCTAssertEqual(gains(x).reduce(0) { $0 + $1 * $1 }, 1, accuracy: 1e-9)
        }
    }

    func testTheDefaultListenerPansPlusXToTheRight() throws {
        var state = ShowState(show: Show(name: "P"), system: SystemLayer(speakers: [
            Speaker(number: 1, output: 1, position: Position(-4, 0, 5)), Speaker(number: 2, output: 2, position: Position(4, 0, 5)),
        ]))
        try state.apply(.setGroup(group: SpeakerGroup(number: 1, name: "LR", renderer: .pan, speakers: state.system.speakers.map(\.id))))
        let config = state.engineConfig(base: EngineConfig())
        let a = try XCTUnwrap(config.groups.first?.panAxis)
        XCTAssertGreaterThan(a.x, 0.99, "a listener facing the stage has +x on the right")
    }

    func testLFEGroupAlgorithms() throws {
        var state = ShowState(show: Show(name: "L"), system: SystemLayer(speakers: [
            Speaker(number: 1, output: 1, position: Position(-4, 0, 5)), Speaker(number: 2, output: 2, position: Position(4, 0, 5)),
            Speaker(number: 3, output: 3, position: Position(-3, 0, 0)), Speaker(number: 4, output: 4, position: Position(3, 0, 0)),
        ]))
        let ids = state.system.speakers.map(\.id)
        try state.apply(.setGroup(group: SpeakerGroup(number: 1, name: "Main", renderer: .delay, speakers: Array(ids.prefix(2)))))
        try state.apply(.setLFESpeakers(speakers: Array(ids.suffix(2))))
        try state.apply(.setSource(source: Source(number: 1, input: 1, position: Position(-3, 2, 1.6), lfeDB: -6)))
        var c = state.engineConfig(base: EngineConfig())
        XCTAssertEqual(c.lfeOutputs, "3, 4", "equal: straight to every sub")
        XCTAssertEqual(c.sources[0].lfeDB, -6)
        try c.validate()
        for mode in [LFEMode.delay, .dbap, .pan] {
            try state.apply(.setLFE(mode: mode, gainDB: -3))
            c = state.engineConfig(base: EngineConfig())
            XCTAssertNil(c.lfeOutputs)
            XCTAssertNil(c.sources[0].lfeDB)
            XCTAssertEqual(c.sources[0].groups?[ShowState.lfeGroupName], -9, "\(mode): the send plus the group's level")
            XCTAssertNoThrow(try c.validate(), "\(mode)")
        }
        // Pan: the source on the left plays the left sub only.
        let r = try SpatialRenderer(config: c)
        let taps = r.makeState()
        XCTAssertGreaterThan(taps.tapCount, 0)
        XCTAssertThrowsError(try state.apply(.setGroup(group: SpeakerGroup(number: 2, name: ShowState.lfeGroupName, renderer: .dbap, speakers: []))))
    }
}

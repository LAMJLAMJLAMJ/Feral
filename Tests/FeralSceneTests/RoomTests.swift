import FeralCore
import FeralScene
import Foundation
import XCTest

final class RoomTests: XCTestCase {
    let low = Position(-10, -10, 0), high = Position(10, 10, 8)

    func testImageSourcesArriveAfterTheDirectSoundEarliestFirst() {
        let r = ImageSources.reflections(source: Position(0, -5, 1.5), listener: Position(0, 5, 1.2), low: low, high: high,
                                         absorption: 0.3, speedOfSound: 343)
        XCTAssertEqual(r.count, Int(FERAL_MAX_REFLECTIONS))
        XCTAssertEqual(r.filter { $0.order == 1 }.count, 6, "every first-order reflection is kept")
        XCTAssertEqual(r.map(\.delay), r.map(\.delay).sorted())
        XCTAssertTrue(r.allSatisfy { $0.delay >= 0.001 && $0.gain > 0 && $0.gain <= 1 })
        // The floor bounce: the image is at z = -1.5; its path is sqrt(10² + 2.7²).
        let floor = r.first { abs($0.image.z + 1.5) < 1e-9 && $0.order == 1 }!
        XCTAssertEqual(floor.delay, ((100 + 2.7 * 2.7).squareRoot() - (100 + 0.09).squareRoot()) / 343, accuracy: 1e-9)
        XCTAssertEqual(floor.gain, 10.0045 / (100 + 7.29).squareRoot() * 0.7.squareRoot(), accuracy: 1e-3)
        // Harder walls reflect more.
        let hard = ImageSources.reflections(source: Position(0, -5, 1.5), listener: Position(0, 5, 1.2), low: low, high: high,
                                            absorption: 0, speedOfSound: 343)
        XCTAssertGreaterThan(hard[0].gain, r[0].gain)
    }

    func testTailSignsAreUncorrelatedRows() {
        let lines = Int(FERAL_ROOM_LINES)
        for a in 0..<40 {
            for b in (a + 1)..<40 {
                let dot = (0..<lines).map { (ImageSources.tailSign(speaker: a, line: $0) == ImageSources.tailSign(speaker: b, line: $0)) ? 1 : -1 }.reduce(0, +)
                if a < 16 && b < 16 { XCTAssertEqual(dot, 0, "the first 16 speakers are orthogonal") }
                XCTAssertNotEqual(abs(dot), lines, "speakers \(a) and \(b) differ")
            }
        }
    }

    func show() throws -> ShowState {
        let speakers = (1...8).map { k -> Speaker in
            let a = Double(k) * .pi / 4
            return Speaker(number: k, output: k, position: Position(6 * sin(a), 6 * cos(a), 3))
        }
        let sub = Speaker(number: 9, output: 9, position: Position(0, 0, 0), type: "sub")
        let ring = SpeakerGroup(number: 1, name: "Ring", renderer: .vbap, speakers: speakers.map(\.id))
        let vox = Source(number: 1, name: "Vox", input: 1, position: Position(0, -3, 1.6), sends: [GroupSend(group: ring.id)],
                         distance: SourceDistance(on: true, rolloffDB: 6, referenceM: 1, air: 0))
        var state = ShowState(show: Show(name: "T", sources: [vox], groups: [ring]),
                              system: SystemLayer(speakers: speakers + [sub], lfeSpeakers: [sub.id], listener: Listener()))
        try state.validate()
        state.show.rooms = []
        return state
    }

    func base() -> EngineConfig { EngineConfig(inputs: 4, outputs: 10) }

    func testRoomsInTheShow() throws {
        var state = try show()
        let hall = Room(number: 1, name: "Hall")
        XCTAssertEqual(try state.apply(.setRoom(room: hall)), .layout(crossfade: true))
        var changed = hall
        changed.decayS = 5
        XCTAssertEqual(try state.apply(.setRoom(room: changed)), .layout(crossfade: false), "a change glides in the core")
        for k in 2...Room.maxRooms { try state.apply(.setRoom(room: Room(number: k, name: "R\(k)"))) }
        XCTAssertThrowsError(try state.apply(.setRoom(room: Room(number: 9, name: "One too many"))))
        var bad = hall
        bad.decayS = 0
        XCTAssertThrowsError(try state.apply(.setRoom(room: bad)))

        let vox = state.show.sources[0]
        try state.apply(.updateSources(updates: [SourceUpdate(id: vox.id, values: SourceValues(reverb: SourceReverb(room: hall.id, sendDB: -3)))]))
        XCTAssertEqual(state.show.sources[0].reverb?.sendDB, -3)
        XCTAssertThrowsError(try state.apply(.updateSources(updates: [SourceUpdate(id: vox.id, values: SourceValues(reverb: SourceReverb(room: UUID())))])))
        // A snapshot stores it, and removing the room takes it off the source and the snapshot.
        try state.apply(.captureSnapshot(capture: SnapshotCapture(number: 1, name: "A", fields: [.reverb])))
        XCTAssertEqual(state.show.snapshots[0].sources[0].values.reverb?.room, hall.id)
        try state.apply(.removeRoom(id: hall.id))
        XCTAssertNil(state.show.sources[0].reverb)
        XCTAssertEqual(state.show.snapshots[0].sources[0].values.reverb, .off)

        // The file keeps rooms.
        let data = try JSONEncoder().encode(state.show)
        XCTAssertEqual(try JSONDecoder().decode(Show.self, from: data).rooms, state.show.rooms)
    }

    func testRoomsPlayOnEverySpeakerButTheSubsOrOnASubset() throws {
        var state = try show()
        var hall = Room(number: 1, name: "Hall")
        try state.apply(.setRoom(room: hall))
        XCTAssertEqual(state.roomConfigs()[0].speakers, Array(1...8), "every speaker but the LFE one")
        hall.useSpeakerSubset = true
        hall.speakers = [state.system.speakers[2].id, state.system.speakers[5].id]
        try state.apply(.setRoom(room: hall))
        XCTAssertEqual(state.roomConfigs()[0].speakers, [3, 6])
        // The box sits under the listener.
        XCTAssertEqual(state.roomConfigs()[0].low, Position(-10, -12.5, 0))
        XCTAssertEqual(state.roomConfigs()[0].high, Position(10, 12.5, 10))
        try state.apply(.removeSpeaker(id: state.system.speakers[2].id))
        XCTAssertEqual(state.show.rooms[0].speakers.count, 1, "a removed speaker leaves its rooms")
    }

    func testTheRendererPlaysTheRoomAndTheReflections() throws {
        var state = try show()
        let hall = Room(number: 1, name: "Hall", width: 20, depth: 20, height: 8)
        try state.apply(.setRoom(room: hall))
        let vox = state.show.sources[0]
        try state.apply(.updateSources(updates: [SourceUpdate(id: vox.id, values: SourceValues(reverb: SourceReverb(room: hall.id, sendDB: -6)))]))
        let config = state.engineConfig(base: base())
        try config.validate()
        XCTAssertEqual(config.sources[0].reverb?.room, 0)
        XCTAssertEqual(config.sources[0].reverb?.sendDB, -6, "no distance modelling on the send")
        XCTAssertLessThan(config.sources[0].gainDB, 0, "while the direct sound has it")
        let renderer = try SpatialRenderer(config: config)
        guard let rv = renderer.allReverbs[0] else { return XCTFail("the source plays into the room") }
        XCTAssertEqual(rv.send, Float(pow(10, -6.0 / 20)), accuracy: 1e-6)
        XCTAssertEqual(rv.reflections.count, Int(FERAL_MAX_REFLECTIONS))
        let outs = Set(rv.reflections.flatMap { $0.outputs.map(\.output) })
        XCTAssertTrue(outs.isSubset(of: Set(0..<8)), "reflections play on the room's speakers, not the sub")
        let state0 = renderer.makeState()
        // The direct sound (VBAP: up to 2 speakers in 2D), 16 lines on 8 speakers, the reflections' pans.
        XCTAssertEqual(state0.tapCount, renderer.allTaps[0].count + 16 * 8 + rv.reflections.reduce(0) { $0 + $1.outputs.count })

        // Moving the source moves its reflections; muting the room takes it all away.
        renderer.move(source: 0, to: Position(4, 4, 1.6))
        XCTAssertNotEqual(renderer.allReverbs[0]?.reflections.map(\.delay), rv.reflections.map(\.delay))
        var muted = hall
        muted.mute = true
        try state.apply(.setRoom(room: muted))
        let quiet = try SpatialRenderer(config: state.engineConfig(base: base()))
        XCTAssertNil(quiet.allReverbs[0])
        XCTAssertEqual(quiet.makeState().tapCount, quiet.allTaps[0].count)
    }

    func testReverbFades() {
        let a = UUID(), b = UUID()
        let from = SourceReverb(room: a, sendDB: -10, earlyDB: -4), to = SourceReverb(room: a, sendDB: 0, early: false)
        let mid = SnapshotFade.values(from: SourceValues(reverb: from), to: SourceValues(reverb: to), at: 0.5).reverb!
        XCTAssertEqual(mid.room, a)
        XCTAssertEqual(mid.sendDB, -5, accuracy: 1e-9)
        XCTAssertEqual(mid.earlyDB, -32, accuracy: 1e-9, "reflections turning off fade to -60 dB")
        XCTAssertEqual(SnapshotFade.values(from: SourceValues(reverb: from), to: SourceValues(reverb: to), at: 1).reverb, to)
        // Into another room: out of the first by halfway, then into the second.
        let other = SourceReverb(room: b, sendDB: -2)
        let early = SnapshotFade.values(from: SourceValues(reverb: from), to: SourceValues(reverb: other), at: 0.25).reverb!
        XCTAssertEqual(early.room, a)
        XCTAssertEqual(early.sendDB, -35, accuracy: 1e-9)
        let late = SnapshotFade.values(from: SourceValues(reverb: from), to: SourceValues(reverb: other), at: 0.75).reverb!
        XCTAssertEqual(late.room, b)
        XCTAssertEqual(late.sendDB, -31, accuracy: 1e-9)
        // From none: up from -60 dB in the new room.
        let on = SnapshotFade.values(from: SourceValues(reverb: .off), to: SourceValues(reverb: other), at: 0.5).reverb!
        XCTAssertEqual(on.room, b)
        XCTAssertEqual(on.sendDB, -31, accuracy: 1e-9)
    }
}

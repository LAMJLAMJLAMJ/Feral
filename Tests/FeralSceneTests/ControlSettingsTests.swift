import FeralScene
import Foundation
import XCTest

final class ControlSettingsTests: XCTestCase {
    func testADMBoxMapsBothWays() {
        let box = ADMBox(min: Position(-8, -1, 0), max: Position(8, 15, 12))
        for p in [Position(0, 7, 6), Position(-8, 15, 0), Position(3.5, 2, 9)] {
            let a = box.adm(p)
            let back = box.position(adm: a.x, a.y, a.z)
            XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
            XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
            XCTAssertEqual(back.z, p.z, accuracy: 1e-9)
        }
        XCTAssertEqual(box.position(adm: 5, -5, 0), Position(-8, 15, 6), "clamped to the box")
        let c = ADMBox.cartesian(azimuth: -90, elevation: 0, distance: 1)
        XCTAssertEqual(c.x, 1, accuracy: 1e-12, "negative azimuth is to the right")
        let p = ADMBox.polar(x: 0.3, y: 0.4, z: 0.5)
        let c2 = ADMBox.cartesian(azimuth: p.azimuth, elevation: p.elevation, distance: p.distance)
        XCTAssertEqual(c2.x, 0.3, accuracy: 1e-12)
        XCTAssertEqual(c2.y, 0.4, accuracy: 1e-12)
        XCTAssertEqual(c2.z, 0.5, accuracy: 1e-12)
    }

    /// The trigger map reads as plainly as the README shows it.
    func testTriggersReadFromJSON() throws {
        let json = """
        { "name": "S", "control": {
            "mscDeviceID": 1,
            "triggers": [
              { "on": { "midiProgram": { "program": 5 } }, "action": { "go": { "cue": "12" } } },
              { "name": "every snapshot", "on": { "midiProgram": {} }, "action": { "go": { "cue": "{value}" } } },
              { "on": { "osc": { "address": "/digico/snap" } }, "action": { "recall": { "snapshot": "{value}", "fadeSeconds": 2 } } },
              { "on": { "msc": { "command": "stop" } }, "action": { "stop": {} }, "enabled": false }
            ] } }
        """
        let show = try JSONDecoder().decode(Show.self, from: Data(json.utf8))
        let t = show.control.triggers
        XCTAssertEqual(t.count, 4)
        XCTAssertEqual(t[0].on, .midiProgram(channel: nil, program: 5))
        XCTAssertEqual(t[1].action.filled(with: "7"), .go(cue: "7"))
        XCTAssertEqual(t[2].action, .recall(snapshot: "{value}", fadeSeconds: 2))
        XCTAssertFalse(t[3].enabled)
        XCTAssertEqual(show.control.mscDeviceID, 1)
        XCTAssertEqual(show.control.admBox, ADMBox())
        // And back.
        let again = try JSONDecoder().decode(Show.self, from: JSONEncoder().encode(show))
        XCTAssertEqual(again, show)
        // A milestone 3 show has none.
        XCTAssertEqual(try JSONDecoder().decode(Show.self, from: Data(#"{"name":"Old"}"#.utf8)).control, ControlSettings())
    }

    func testSetControlChecksAndJournals() throws {
        var state = ShowState(show: Show(name: "S"))
        let good = ControlSettings(admBox: ADMBox(min: Position(-5, 0, 0), max: Position(5, 10, 6)),
                                   triggers: [Trigger(on: .midiNote(channel: 10, note: 36), action: .go(cue: nil))])
        XCTAssertEqual(try state.apply(.setControl(control: good)), .none)
        XCTAssertEqual(state.show.control, good)
        for bad in [ControlSettings(admBox: ADMBox(min: Position(0, 0, 0), max: Position(0, 10, 6))),
                    ControlSettings(triggers: [Trigger(on: .osc(address: "nope", value: nil), action: .stop)]),
                    ControlSettings(mscDeviceID: 127)] {
            XCTAssertThrowsError(try state.apply(.setControl(control: bad)))
        }
        XCTAssertEqual(state.show.control, good, "a refused change leaves the show as it was")
        let entry = JournalEntry(seq: 1, origin: "t", command: .setControl(control: good))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(JournalEntry.self, from: encoder.encode(entry)).command, entry.command)
    }

    func testSnapshotWithoutLivePositions() {
        let a = UUID(), b = UUID()
        let snap = Snapshot(number: 1, name: "S", sources: [
            SourceUpdate(id: a, values: SourceValues(position: Position(1, 2, 3), gainDB: -3)),
            SourceUpdate(id: b, values: SourceValues(position: Position(4, 5, 6))),
        ])
        let kept = snap.withoutPositions(of: [a, b])
        XCTAssertEqual(kept.sources, [SourceUpdate(id: a, values: SourceValues(gainDB: -3))], "b had only a position, so it drops out")
        XCTAssertEqual(snap.withoutPositions(of: []), snap)
    }

    func testCueReclaimReadsAndDefaults() throws {
        let cue = try JSONDecoder().decode(Cue.self, from: Data(#"{"id":"\#(UUID().uuidString)","number":"3"}"#.utf8))
        XCTAssertFalse(cue.reclaim)
        var c = cue
        c.reclaim = true
        XCTAssertTrue(try JSONDecoder().decode(Cue.self, from: JSONEncoder().encode(c)).reclaim)
    }

    func testEngineSettingsForOSCAndMIDI() throws {
        let d = try JSONDecoder().decode(EngineConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(d.oscPort, 9200)
        XCTAssertEqual(d.oscAddress, "0.0.0.0")
        XCTAssertTrue(d.midi)
        XCTAssertNil(d.midiInputs)
        var c = d
        c.oscPort = c.controlPort
        XCTAssertThrowsError(try c.validate())
        c.oscPort = 0
        XCTAssertNoThrow(try c.validate(), "0 turns OSC off")
    }
}

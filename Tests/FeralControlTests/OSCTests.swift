import FeralControl
import FeralScene
import Foundation
import XCTest

final class OSCTests: XCTestCase {
    func testMessagesRoundTrip() throws {
        let messages = [
            OSCMessage("/feral/go"),
            OSCMessage("/feral/source/12/xyz", [.float(1.5), .float(-2), .float(0.25)]),
            OSCMessage("/a", [.int(-7), .string("Act 1"), .string(""), .blob(Data([1, 2, 3])), .int64(1 << 40),
                              .double(0.1), .bool(true), .bool(false), .none]),
        ]
        for m in messages { XCTAssertEqual(try OSC.messages(in: OSC.encode(m)), [m]) }
        XCTAssertEqual(try OSC.messages(in: OSC.bundle(messages)), messages)
    }

    /// The bytes QLab or Max would send, written out by hand from the OSC 1.0 spec.
    func testKnownBytes() throws {
        var bytes = Array("/feral/cue/5/go".utf8) + [0]               // 16 bytes
        bytes += Array(",i".utf8) + [0, 0]                            // 4
        bytes += [0, 0, 0, 3]
        XCTAssertEqual(try OSC.messages(in: Data(bytes)), [OSCMessage("/feral/cue/5/go", [.int(3)])])
        XCTAssertEqual(OSC.encode(OSCMessage("/feral/cue/5/go", [.int(3)])), Data(bytes))
        // A float 1.0 is 3F 80 00 00.
        let f = OSC.encode(OSCMessage("/x", [.float(1)]))
        XCTAssertEqual(Array(f.suffix(4)), [0x3F, 0x80, 0, 0])
        // No type tag string at all: an old sender's message with no arguments.
        XCTAssertEqual(try OSC.messages(in: Data(Array("/feral/go".utf8) + [0, 0, 0])), [OSCMessage("/feral/go")])
    }

    func testValuesAsNumbersAndText() {
        XCTAssertEqual(OSCValue.int(5).text, "5")
        XCTAssertEqual(OSCValue.float(5).text, "5", "QLab sends cue numbers as floats")
        XCTAssertEqual(OSCValue.float(5.5).text, "5.5")
        XCTAssertEqual(OSCValue.string(" 2.5").number, 2.5)
        XCTAssertEqual(OSCValue.bool(true).number, 1)
        XCTAssertNil(OSCValue.blob(Data()).number)
    }

    func testMalformedPacketsAreRefused() {
        let bad: [[UInt8]] = [
            [], [0x2F], [0x2F, 0, 0],                                 // too short
            Array("/abc".utf8),                                        // no end to the address
            Array("abc".utf8) + [0],                                   // no slash
            Array("/a".utf8) + [0, 0] + Array(",i".utf8) + [0, 0],     // an int with no bytes
            Array("/a".utf8) + [0, 0] + Array(",q".utf8) + [0, 0],     // an unknown type
            Array("/a".utf8) + [0, 0] + Array(",b".utf8) + [0, 0] + [0x7F, 0xFF, 0xFF, 0xFF], // a huge blob
            Array("#bundle".utf8) + [0] + [0, 0, 0, 0, 0, 0, 0, 1] + [0, 0, 0, 64], // an element past the end
            Array("#bundle".utf8) + [0] + [0, 0, 0, 0, 0, 0, 0, 1] + [0xFF, 0xFF, 0xFF, 0xFC], // a negative size
        ]
        for b in bad { XCTAssertThrowsError(try OSC.messages(in: Data(b)), "\(b)") }
    }

    func testDeepBundlesAreRefused() {
        var packet = OSC.encode(OSCMessage("/x"))
        for _ in 0...OSC.maxDepth {
            var b = Array("#bundle".utf8) + [0] + [0, 0, 0, 0, 0, 0, 0, 1]
            let n = UInt32(packet.count)
            b += [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
            packet = Data(b) + packet
        }
        XCTAssertThrowsError(try OSC.messages(in: packet))
    }

    /// Random and mangled packets never crash the reader: the design's protocol fuzzing.
    func testFuzz() {
        var rng = SplitMix(seed: 42)
        let good = OSC.bundle([OSCMessage("/feral/source/1/xyz", [.float(1), .float(2), .float(3)]),
                               OSCMessage("/a", [.string("hello"), .blob(Data([9, 9])), .int(4)])])
        for i in 0..<20_000 {
            var bytes: [UInt8]
            if i % 2 == 0 {
                bytes = (0..<Int(rng.next() % 96)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
                if i % 4 == 0 && !bytes.isEmpty { bytes[0] = UInt8(ascii: i % 8 == 0 ? "#" : "/") }
            } else {
                bytes = Array(good)
                for _ in 0..<(1 + Int(rng.next() % 4)) { bytes[Int(rng.next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: rng.next()) }
                if rng.next() % 3 == 0 { bytes = Array(bytes.prefix(Int(rng.next() % UInt64(bytes.count)))) }
            }
            _ = try? OSC.messages(in: Data(bytes))
            var parser = MIDIParser()
            _ = parser.feed(bytes)
        }
    }
}

final class MIDITests: XCTestCase {
    func testChannelMessages() {
        var p = MIDIParser()
        XCTAssertEqual(p.feed([0xC0, 4]), [.programChange(channel: 1, program: 5)])
        XCTAssertEqual(p.feed([0x9F, 60, 100, 61, 0, 62, 1]), [.noteOn(channel: 16, note: 60, velocity: 100),
                                                             .noteOn(channel: 16, note: 62, velocity: 1)],
                       "running status, and velocity 0 is a note off")
        XCTAssertEqual(p.feed([0xB2, 20]), [])
        XCTAssertEqual(p.feed([0xF8, 127]), [.controlChange(channel: 3, controller: 20, value: 127)], "a clock in the middle")
        XCTAssertEqual(p.feed([0x80, 60, 0, 0xE0, 0, 64]), [], "note off and pitch bend are not used")
        XCTAssertEqual(p.feed([5]), [], "half a pitch bend")
    }

    func testShowControl() {
        var p = MIDIParser()
        // GO cue 12.5 list 1, sound general, device 1, split across two packets.
        let go: [UInt8] = [0xF0, 0x7F, 0x01, 0x02, 0x10, 0x01] + Array("12.5".utf8) + [0] + Array("1".utf8) + [0xF7]
        XCTAssertEqual(p.feed(Array(go.prefix(7))), [])
        XCTAssertEqual(p.feed(Array(go.dropFirst(7))), [.showControl(MSCMessage(deviceID: 1, command: .go, cue: "12.5", list: "1"))])
        XCTAssertEqual(p.feed([0xF0, 0x7F, 0x7F, 0x02, 0x7F, 0x02, 0xF7]), [.showControl(MSCMessage(deviceID: 127, command: .stop))])
        XCTAssertEqual(p.feed([0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7]), [], "other sysex is ignored")
        XCTAssertEqual(p.feed([0xF0, 0x7F, 0x01, 0x02, 0x10, 0x01, 0x31, 0xC0, 3]), [.programChange(channel: 1, program: 4)],
                       "a status byte ends an unfinished sysex")
        let timed = MSCMessage(deviceID: 2, command: .timedGo, cue: "7")
        XCTAssertEqual(MSCMessage.parse(timed.bytes), timed)
        for m: MIDIMessage in [.programChange(channel: 3, program: 128), .noteOn(channel: 1, note: 1, velocity: 2),
                               .controlChange(channel: 16, controller: 7, value: 0), .showControl(MSCMessage(deviceID: 1, command: .go, cue: "3"))] {
            var q = MIDIParser()
            XCTAssertEqual(q.feed(m.bytes), [m])
        }
    }
}

final class ControlMapperTests: XCTestCase {
    let main = SpeakerGroup(number: 1, name: "Main", renderer: .delay, speakers: [])
    lazy var vox = Source(number: 1, name: "Vox", input: 1, position: Position(0, 2, 1.6), sends: [GroupSend(group: main.id)])
    lazy var keys = Source(number: 7, name: "Keys", input: 2, position: Position(3, 1, 1))
    lazy var snap = Snapshot(number: 3, name: "Act 1")
    lazy var cue = Cue(number: "12.5", snapshot: snap.id)

    func state(_ control: ControlSettings = ControlSettings()) -> ShowState {
        ShowState(show: Show(name: "T", sources: [vox, keys], groups: [main], snapshots: [snap], cues: [cue], control: control))
    }

    func actions(_ address: String, _ args: [OSCValue] = [], _ s: ShowState? = nil) throws -> [ControlAction] {
        try ControlMapper(state: s ?? state()).actions(for: OSCMessage(address, args))
    }

    func update(_ source: Source, _ v: SourceValues, owner: PositionOwner? = nil) -> [ControlAction] {
        [.update([SourceUpdate(id: source.id, values: v)], owner: owner)]
    }

    func testFeralNamespace() throws {
        XCTAssertEqual(try actions("/feral/go"), [.go(cue: nil)])
        XCTAssertEqual(try actions("/feral/go", [.float(12.5)]), [.go(cue: "12.5")])
        XCTAssertEqual(try actions("/feral/cue/12.5/go"), [.go(cue: "12.5")])
        XCTAssertEqual(try actions("/feral/stop"), [.stopFades])
        XCTAssertEqual(try actions("/feral/snapshot/3/recall"), [.recall(snapshot: "3", fadeSeconds: nil)])
        XCTAssertEqual(try actions("/feral/snapshot/3/recall", [.int(4)]), [.recall(snapshot: "3", fadeSeconds: 4)])
        XCTAssertEqual(try actions("/feral/ping", [.int(1)]), [.reply(OSCMessage("/feral/pong", [.int(1)]))])
        XCTAssertEqual(try actions("/feral/subscribe", [.int(9300), .string("adm")]), [.subscribe(port: 9300, adm: true)])
        XCTAssertEqual(try actions("/feral/subscribe"), [.subscribe(port: nil, adm: false)])
        XCTAssertEqual(try actions("/feral/source/1/xyz", [.float(1), .int(2), .float(3)]),
                       update(vox, SourceValues(position: Position(1, 2, 3)), owner: .osc))
        XCTAssertEqual(try actions("/feral/source/7/y", [.float(5)]), update(keys, SourceValues(position: Position(3, 5, 1)), owner: .osc))
        XCTAssertEqual(try actions("/feral/source/1/gain", [.float(-6)]), update(vox, SourceValues(gainDB: -6)))
        XCTAssertEqual(try actions("/feral/source/1/mute", [.bool(true)]), update(vox, SourceValues(mute: true)))
        XCTAssertEqual(try actions("/feral/source/1/lfe", [.string("off")]), update(vox, SourceValues(lfeOff: true)))
        XCTAssertEqual(try actions("/feral/source/1/send/main", [.float(-3)]),
                       update(vox, SourceValues(sends: [GroupSend(group: main.id, gainDB: -3)])))
        XCTAssertEqual(try actions("/feral/source/7/send/1", [.float(-3)]),
                       update(keys, SourceValues(sends: [GroupSend(group: main.id, gainDB: -3)])))
        XCTAssertEqual(try actions("/feral/source/7/release"), [.release([keys.id])])
        guard case .apply(.captureSnapshot(let c))? = try actions("/feral/snapshot/store", [.string("New")]).first else {
            return XCTFail("store makes a snapshot")
        }
        XCTAssertEqual(c.number, 4)
        XCTAssertEqual(c.name, "New")
    }

    func testBadMessagesAreRefused() {
        for (address, args) in [("/feral/source/9/xyz", [OSCValue.float(1), .float(2), .float(3)]),   // no source 9
                                ("/feral/source/1/xyz", [.float(1), .float(2)]),                       // too few
                                ("/feral/source/1/gain", [.string("loud")]),
                                ("/feral/source/1/gain", [.float(.nan)]),
                                ("/feral/source/1/send/Top", [.float(0)]),                             // no such group
                                ("/feral/snapshot/3/recall", [.float(-1)]),
                                ("/feral/subscribe", [.int(70_000)]),
                                ("/feral/nothing", []), ("/qlab/go", []), ("/adm/obj/1", []), ("/adm/obj/1/spin", [])] {
            XCTAssertThrowsError(try actions(address, args), address)
        }
    }

    func testADMOSC() throws {
        let box = ADMBox(min: Position(-10, -2, 0), max: Position(10, 20, 10))
        let s = state(ControlSettings(admBox: box))
        XCTAssertEqual(try actions("/adm/obj/1/xyz", [.float(0), .float(0), .float(-1)], s),
                       update(vox, SourceValues(position: Position(0, 9, 0)), owner: .osc), "the centre of the box, on the floor")
        XCTAssertEqual(try actions("/adm/obj/1/xyz", [.float(-1), .float(1), .float(1)], s),
                       update(vox, SourceValues(position: Position(10, -2, 10)), owner: .osc), "front left as the audience sees it is stage right")
        XCTAssertEqual(try actions("/adm/obj/7/gain", [.float(0.5)], s), update(keys, SourceValues(gainDB: 20 * log10(0.5))))
        XCTAssertEqual(try actions("/adm/obj/7/w", [.float(0.5)], s), update(keys, SourceValues(width: 90)))
        XCTAssertEqual(try actions("/adm/obj/7/name", [.string("Keys")], s), [])
        // Azimuth 90 is hard left (stage right), on the floor plane half way out.
        guard case .update(let u, .osc)? = try actions("/adm/obj/1/aed", [.float(90), .float(0), .float(1)], s).first,
              let p = u.first?.values.position else { return XCTFail("aed moves the source") }
        XCTAssertEqual(p.x, 10, accuracy: 1e-9)
        XCTAssertEqual(p.y, 9, accuracy: 1e-9)
        XCTAssertEqual(p.z, 5, accuracy: 1e-9)
        // One polar value keeps the others.
        guard case .update(let u2, _)? = try actions("/adm/obj/1/dist", [.float(0)], s).first,
              let p2 = u2.first?.values.position else { return XCTFail("dist moves the source") }
        XCTAssertEqual(p2.x, 0, accuracy: 1e-9)
        XCTAssertEqual(p2.y, 9, accuracy: 1e-9)
    }

    func testTriggerMap() {
        let control = ControlSettings(triggers: [
            Trigger(on: .midiProgram(channel: nil, program: nil), action: .go(cue: "{value}")),
            Trigger(on: .midiProgram(channel: 2, program: 5), action: .recall(snapshot: "3", fadeSeconds: 2)),
            Trigger(enabled: false, on: .midiNote(channel: nil, note: 60), action: .stop),
            Trigger(on: .midiControl(channel: 1, controller: 20, value: 127), action: .stop),
            Trigger(on: .osc(address: "/digico/snapshot", value: nil), action: .go(cue: "{value}")),
            Trigger(on: .osc(address: "/qlab/stop", value: "1"), action: .stop),
        ])
        let m = ControlMapper(state: state(control))
        XCTAssertEqual(m.triggered(by: .programChange(channel: 1, program: 12)), [.go(cue: "12")])
        XCTAssertEqual(m.triggered(by: .programChange(channel: 2, program: 5)), [.go(cue: "5"), .recall(snapshot: "3", fadeSeconds: 2)])
        XCTAssertEqual(m.triggered(by: .noteOn(channel: 1, note: 60, velocity: 1)), [], "a trigger that is off")
        XCTAssertEqual(m.triggered(by: .controlChange(channel: 1, controller: 20, value: 127)), [.stopFades])
        XCTAssertEqual(m.triggered(by: .controlChange(channel: 1, controller: 20, value: 0)), [])
        XCTAssertEqual(m.triggered(by: OSCMessage("/digico/snapshot", [.int(7)])), [.go(cue: "7")])
        XCTAssertEqual(m.triggered(by: OSCMessage("/qlab/stop", [.int(1)])), [.stopFades])
        XCTAssertEqual(m.triggered(by: OSCMessage("/qlab/stop", [.int(0)])), [])
        XCTAssertNoThrow(try control.check())
        XCTAssertThrowsError(try ControlSettings(triggers: [Trigger(on: .midiProgram(channel: 17, program: nil), action: .stop)]).check())
    }

    func testShowControlWithoutTriggers() {
        let mine = ControlMapper(state: state(ControlSettings(mscDeviceID: 1)))
        XCTAssertEqual(mine.triggered(by: .showControl(MSCMessage(deviceID: 1, command: .go, cue: "12.5"))), [.go(cue: "12.5")])
        XCTAssertEqual(mine.triggered(by: .showControl(MSCMessage(deviceID: 127, command: .go))), [.go(cue: nil)])
        XCTAssertEqual(mine.triggered(by: .showControl(MSCMessage(deviceID: 2, command: .go))), [], "another device's")
        XCTAssertEqual(mine.triggered(by: .showControl(MSCMessage(deviceID: 1, command: .stop))), [.stopFades])
        let triggered = ControlMapper(state: state(ControlSettings(triggers: [
            Trigger(on: .msc(command: .go, cue: "5"), action: .recall(snapshot: "3", fadeSeconds: nil))])))
        XCTAssertEqual(triggered.triggered(by: .showControl(MSCMessage(deviceID: 9, command: .go, cue: "5"))),
                       [.recall(snapshot: "3", fadeSeconds: nil)], "a trigger replaces the built-in GO")
    }

    func testEcho() {
        var s = state()
        s.show.sources[0].position = Position(10, -2, 10)
        let m = ControlMapper(state: s)
        let move = Command.updateSources(updates: [SourceUpdate(id: vox.id, values: SourceValues(position: Position(10, -2, 10), gainDB: -3))])
        XCTAssertEqual(m.echo(move, adm: false).map(\.address), ["/feral/source/1/xyz", "/feral/source/1/gain"])
        XCTAssertEqual(m.echo(move, adm: false).first?.arguments, [.float(10), .float(-2), .float(10)])
        XCTAssertEqual(m.echo(move, adm: true).first, OSCMessage("/adm/obj/1/xyz", [.float(-1), .float(1), .float(1)]))
        XCTAssertEqual(m.echo(.renameShow(name: "x"), adm: false), [])
        let status = EngineStatus(version: "x", showPath: "/x", currentCue: cue.id)
        XCTAssertEqual(m.cueMessages(status), [OSCMessage("/feral/cue/current", [.string("12.5"), .string("")]),
                                               OSCMessage("/feral/cue/next", [.string(""), .string("")])])
        XCTAssertEqual(m.dump(adm: false, status: nil).filter { $0.address.hasSuffix("/xyz") }.count, 2)
    }
}

/// A small seeded random number generator, so the fuzz test is the same every run.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

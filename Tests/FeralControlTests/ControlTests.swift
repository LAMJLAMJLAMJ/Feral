import FeralControl
import FeralScene
import Foundation
import XCTest

final class MessageTests: XCTestCase {
    func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try Wire.encode(value)
        XCTAssertEqual(data.last, UInt8(ascii: "\n"), file: file, line: line)
        XCTAssertFalse(data.dropLast().contains(UInt8(ascii: "\n")), "one message is one line", file: file, line: line)
        XCTAssertEqual(try Wire.decode(T.self, from: data.dropLast()), value, file: file, line: line)
    }

    func testRequestsAndEventsRoundTrip() throws {
        let id = UUID()
        let requests: [Request] = [
            .hello(client: "test"),
            .apply(command: .updateSources(updates: [SourceUpdate(id: id, values: SourceValues(position: Position(1, 2, 3)))])),
            .apply(command: .captureSnapshot(capture: SnapshotCapture(number: 3, name: "Act 2\nline", fields: [.position]))),
            .apply(command: .setCue(cue: Cue(number: "12.5", snapshot: id, fadeSeconds: 4, curve: .sCurve, autoFollow: true))),
            .recall(snapshot: "3", fadeSeconds: nil),
            .recall(snapshot: "3", fadeSeconds: 2.5),
            .go(cue: nil), .go(cue: "12.5"), .stopFades, .save, .refresh,
        ]
        for r in requests { try roundTrip(r) }
        let status = EngineStatus(version: "0.3", showPath: "/x.feralshow", unsaved: 2, currentCue: id, fading: [id], audio: "running")
        let events: [Event] = [
            .state(state: FullState(seq: 4, show: Show(name: "S"), system: SystemLayer(), status: status)),
            .applied(seq: 5, origin: "app", command: .renameShow(name: "T")),
            .status(status: status),
            .error(message: "no cue 9"),
        ]
        for e in events { try roundTrip(e) }
    }

    /// The wire format is plain enough to type: what OSC and other tools will map onto.
    func testTheWireFormatIsReadable() throws {
        XCTAssertEqual(String(decoding: try Wire.encode(Request.go(cue: "12.5")), as: UTF8.self), #"{"go":{"cue":"12.5"}}"# + "\n")
        XCTAssertEqual(try Wire.decode(Request.self, from: Data(#"{"save":{}}"#.utf8)), .save)
        XCTAssertEqual(try Wire.decode(Request.self, from: Data(#"{"recall":{"snapshot":"2"}}"#.utf8)), .recall(snapshot: "2", fadeSeconds: nil))
    }

    func testLineBufferJoinsAndSplits() throws {
        var b = Wire.LineBuffer()
        XCTAssertEqual(try b.append(Data(#"{"a":"#.utf8)), [])
        XCTAssertEqual(try b.append(Data("1}\n\n{\"b\":2}\n{\"c\"".utf8)), [Data(#"{"a":1}"#.utf8), Data(#"{"b":2}"#.utf8)])
        XCTAssertEqual(try b.append(Data(":3}\n".utf8)), [Data(#"{"c":3}"#.utf8)])
    }

    func testMirrorFollowsTheEngine() {
        var m = MirroredShow()
        let source = Source(number: 1, input: 1, position: Position(0, 0, 0))
        let status = EngineStatus(version: "0.3", showPath: "/x")
        XCTAssertFalse(m.handle(.applied(seq: 1, origin: "x", command: .renameShow(name: "A"))), "nothing to apply to yet")
        m.handle(.state(state: FullState(seq: 7, show: Show(name: "S", sources: [source]), system: SystemLayer(), status: status)))
        XCTAssertTrue(m.handle(.applied(seq: 8, origin: "app", command: .updateSources(updates: [
            SourceUpdate(id: source.id, values: SourceValues(position: Position(1, 2, 0)))]))))
        XCTAssertEqual(m.state?.show.sources[0].position, Position(1, 2, 0))
        XCTAssertFalse(m.handle(.applied(seq: 10, origin: "app", command: .renameShow(name: "B"))), "a missed event asks for a refresh")
        XCTAssertFalse(m.handle(.applied(seq: 11, origin: "app", command: .removeCue(id: UUID()))), "a command that does not apply")
        XCTAssertEqual(m.state?.show.name, "B")
    }
}

#if canImport(Network)
/// The engine's server and the app's client over a real TCP connection on this Mac.
final class LinkTests: XCTestCase {
    func testClientGetsTheStateAndTheServerGetsRequests() throws {
        let queue = DispatchQueue(label: "test.server")
        let server = ControlServer(queue: queue)
        let ready = expectation(description: "listening")
        let gotHello = expectation(description: "hello")
        let gotGo = expectation(description: "go")
        let gotState = expectation(description: "state")
        let gotApplied = expectation(description: "applied")
        server.onReady = { _ in ready.fulfill() }
        server.onConnect = { id in
            server.send(.state(state: FullState(seq: 1, show: Show(name: "Linked"), system: SystemLayer(),
                                                status: EngineStatus(version: "test", showPath: "/x"))), to: id)
        }
        server.onRequest = { _, request in
            switch request {
            case .hello(let name): XCTAssertEqual(name, "tester"); gotHello.fulfill()
            case .go(let cue):
                XCTAssertEqual(cue, "2")
                gotGo.fulfill()
                server.broadcast(.applied(seq: 2, origin: "tester", command: .renameShow(name: "Renamed")))
            default: XCTFail("unexpected \(request)")
            }
        }
        try server.start(address: "127.0.0.1", port: 0)
        wait(for: [ready], timeout: 5)
        let port = try XCTUnwrap(queue.sync { server.port })

        let clientQueue = DispatchQueue(label: "test.client")
        let client = ControlClient(host: "127.0.0.1", port: port, name: "tester", queue: clientQueue)
        var mirror = MirroredShow()
        client.onEvent = { event in
            mirror.handle(event)
            switch event {
            case .state:
                gotState.fulfill()
                client.send(.go(cue: "2"))
            case .applied: gotApplied.fulfill()
            default: break
            }
        }
        client.start()
        wait(for: [gotState, gotHello, gotGo, gotApplied], timeout: 5)
        XCTAssertEqual(clientQueue.sync { mirror.state?.show.name }, "Renamed")
        XCTAssertEqual(clientQueue.sync { mirror.seq }, 2)
        client.stop()
        queue.sync { server.stop() }
    }
}
#endif

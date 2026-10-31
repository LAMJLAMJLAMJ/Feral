import FeralScene
import Foundation
import XCTest

final class ShowTests: XCTestCase {
    /// A milestone 2 engine.json layout: two Delay pairs, a DBAP top, a sub on the LFE send.
    let layout = """
    {
      "inputs": 3, "outputs": 6,
      "speakers": [
        { "output": 1, "name": "L", "position": [-4, 0, 5] },
        { "output": 2, "name": "R", "position": [4, 0, 5], "delayMS": 1.5, "trimDB": -3, "invert": true },
        { "output": 3, "position": [-4, 10, 5] },
        { "output": 4, "position": [4, 10, 5], "eq": [{ "type": "peak", "hz": 2000, "gainDB": -4 }], "limiterDB": -2 },
        { "output": 5, "position": [0, 5, 8] },
        { "output": 6, "name": "Sub", "position": [0, 0, 0] }
      ],
      "groups": [
        { "name": "Main", "renderer": "delay", "speakers": "1-2, 3-4", "weightsDB": { "3": -3 } },
        { "name": "Top", "renderer": "dbap", "speakers": 5 }
      ],
      "lfeOutputs": "6",
      "sources": [
        { "input": 1, "position": [0, 2, 1.6] },
        { "input": 2, "name": "Vox", "position": [-2, 1], "groups": { "Main": -2 }, "lfeDB": -6 },
        { "input": 3, "name": "Keys", "position": [3, 1, 1], "gainDB": -4, "groups": ["Top"] }
      ]
    }
    """

    func config() throws -> EngineConfig {
        let c = try JSONDecoder().decode(EngineConfig.self, from: Data(layout.utf8))
        try c.validate()
        return c
    }

    func imported() throws -> ShowState { try ShowState.importing(try config(), name: "Test") }

    func temporaryPackage() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Test.feralshow")
    }

    // MARK: The show and the renderer

    /// A show imported from engine.json renders exactly what engine.json did.
    func testImportedShowRendersTheSameTaps() throws {
        let original = try config()
        let state = try imported()
        XCTAssertEqual(state.system.speakers.count, 6)
        XCTAssertEqual(state.show.groups.map(\.name), ["Main", "Top"])
        XCTAssertEqual(state.show.sources[0].sends.count, 2, "no groups listed means every group")
        XCTAssertEqual(state.show.sources[1].sends.map(\.gainDB), [-2])
        XCTAssertEqual(state.system.lfeSpeakers.count, 1)
        let rebuilt = state.engineConfig(base: original)
        XCTAssertNoThrow(try rebuilt.validate())
        let a = try SpatialRenderer(config: original).allTaps
        let b = try SpatialRenderer(config: rebuilt).allTaps
        XCTAssertEqual(a.count, b.count)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.sorted { ($0.output, $0.group) < ($1.output, $1.group) },
                           y.sorted { ($0.output, $0.group) < ($1.output, $1.group) })
        }
    }

    /// Updating one source in the renderer gives the taps a fresh renderer would.
    func testRendererUpdateMatchesARebuild() throws {
        var state = try imported()
        let base = try config()
        let r = try SpatialRenderer(config: state.engineConfig(base: base))
        let vox = state.show.sources[1].id
        let main = state.show.groups[0].id, top = state.show.groups[1].id
        let change = try state.apply(.updateSources(updates: [SourceUpdate(id: vox, values: SourceValues(
            position: Position(3, 6, 2), gainDB: -6, sends: [GroupSend(group: main, gainDB: 0), GroupSend(group: top, gainDB: -3)]))]))
        XCTAssertEqual(change, .sources([vox]))
        r.update(source: 1, to: state.sourceConfig(state.show.sources[1]))
        let fresh = try SpatialRenderer(config: state.engineConfig(base: base))
        XCTAssertEqual(r.allTaps, fresh.allTaps)
        XCTAssertEqual(r.allTaps[1].filter { $0.group == "Top" }.count, 1)
    }

    // MARK: The package and the journal

    func testSaveAndLoadThePackage() throws {
        var state = try imported()
        try state.apply(.captureSnapshot(capture: SnapshotCapture(number: 1, name: "Top", fadeSeconds: 2, curve: .sCurve)))
        try state.apply(.setCue(cue: Cue(number: "1.5", name: "Open", snapshot: state.show.snapshots[0].id, autoFollow: true)))
        let url = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try ShowFile.save(state, to: url)
        let opened = try ShowFile.load(url)
        XCTAssertEqual(opened.state, state)
        XCTAssertEqual(opened.replayed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ShowFile.journalURL(url).path))
    }

    /// Changes since the last save come back from the journal; a line cut short by a crash is skipped.
    func testJournalReplaysUnsavedChanges() throws {
        let saved = try imported()
        let url = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try ShowFile.save(saved, to: url)

        var live = saved
        let vox = live.show.sources[1].id
        let commands: [Command] = [
            .updateSources(updates: [SourceUpdate(id: vox, values: SourceValues(position: Position(1, 1, 1)))]),
            .updateSources(updates: [SourceUpdate(id: vox, values: SourceValues(position: Position(2, 3, 1.5), mute: true))]),
            .captureSnapshot(capture: SnapshotCapture(number: 1, name: "After the move")),
            .renameShow(name: "Renamed"),
        ]
        let journal = try Journal(package: url)
        for (n, c) in commands.enumerated() {
            try live.apply(c)
            try journal.append([JournalEntry(seq: n + 1, origin: "test", command: c)])
        }
        // A crash in the middle of writing a line.
        let h = try FileHandle(forWritingTo: ShowFile.journalURL(url))
        _ = try h.seekToEnd()
        try h.write(contentsOf: Data(#"{"seq":5,"command":{"updateSou"#.utf8))
        try h.close()

        let opened = try ShowFile.load(url)
        XCTAssertEqual(opened.replayed, 4)
        XCTAssertEqual(opened.problems.count, 1)
        XCTAssertEqual(opened.state, live)
        XCTAssertEqual(opened.state.source(vox)?.position, Position(2, 3, 1.5))

        // Saving takes the journal's changes into the files and empties it.
        try ShowFile.save(opened.state, to: url)
        journal.reopen()
        let again = try ShowFile.load(url)
        XCTAssertEqual(again.replayed, 0)
        XCTAssertEqual(again.state, live)
    }

    func testNeighbouringMovesShareOneJournalLine() {
        let a = UUID(), b = UUID()
        func move(_ id: UUID, _ x: Double, mute: Bool? = nil) -> Command {
            .updateSources(updates: [SourceUpdate(id: id, values: SourceValues(position: Position(x, 0, 0), mute: mute))])
        }
        let entries = [move(a, 1), move(a, 2, mute: true), move(b, 5), .renameShow(name: "x"), move(a, 3)].enumerated()
            .map { JournalEntry(seq: $0.offset + 1, origin: "test", command: $0.element) }
        let c = JournalEntry.coalesce(entries)
        XCTAssertEqual(c.count, 3)
        XCTAssertEqual(c[0].seq, 3)
        XCTAssertEqual(c[0].command, .updateSources(updates: [
            SourceUpdate(id: a, values: SourceValues(position: Position(2, 0, 0), mute: true)),
            SourceUpdate(id: b, values: SourceValues(position: Position(5, 0, 0))),
        ]))
        XCTAssertEqual(c[2].command, move(a, 3))
    }

    /// With no show yet, engine.json's layout becomes one (and the path defaults next to engine.json).
    func testOpeningForAConfigWithNoShowImportsIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let configURL = folder.appendingPathComponent("engine.json")
        var c = try config()
        XCTAssertEqual(ShowFile.url(for: c, configURL: configURL).path, folder.appendingPathComponent("Shows/Default.feralshow").path)
        let opened = try ShowFile.open(for: c, configURL: configURL)
        XCTAssertFalse(opened.exists)
        XCTAssertEqual(opened.state.show.sources.count, 3)
        XCTAssertEqual(opened.state.show.name, "Default")
        try ShowFile.save(opened.state, to: opened.url)
        XCTAssertTrue(try ShowFile.open(for: c, configURL: configURL).exists)
        c.show = "Other.feralshow"
        XCTAssertEqual(ShowFile.url(for: c, configURL: configURL).path, folder.appendingPathComponent("Other.feralshow").path)
        c.show = "/Volumes/Show/Tour.feralshow"
        XCTAssertEqual(ShowFile.url(for: c, configURL: configURL).path, "/Volumes/Show/Tour.feralshow")
    }

    /// The example in the repository loads and renders, and its cues run in number order.
    func testExampleShow() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configURL = root.appendingPathComponent("examples/stage-test.json")
        let config = try EngineConfig.load(from: configURL)
        let opened = try ShowFile.open(for: config, configURL: configURL)
        XCTAssertTrue(opened.exists)
        XCTAssertEqual(opened.replayed, 0, "the example's journal should be empty in the repository")
        let s = opened.state
        XCTAssertEqual(s.system.speakers.count, 26)
        XCTAssertEqual(s.show.sources.count, 2)
        XCTAssertEqual(s.orderedCues.map(\.number), ["1", "2", "3", "3.5", "4"])
        let rendered = s.engineConfig(base: config)
        XCTAssertNoThrow(try rendered.validate())
        XCTAssertGreaterThan(try SpatialRenderer(config: rendered).makeState().tapCount, 20)
    }

    // MARK: Commands

    func testBadCommandsChangeNothing() throws {
        var state = try imported()
        let before = state
        let vox = state.show.sources[1].id
        XCTAssertThrowsError(try state.apply(.updateSources(updates: [SourceUpdate(id: UUID(), values: SourceValues(gainDB: 0))])))
        XCTAssertThrowsError(try state.apply(.updateSources(updates: [
            SourceUpdate(id: vox, values: SourceValues(gainDB: -3)),
            SourceUpdate(id: vox, values: SourceValues(sends: [GroupSend(group: UUID())])),
        ])), "a send to a group that does not exist")
        XCTAssertThrowsError(try state.apply(.updateSources(updates: [SourceUpdate(id: vox, values: SourceValues(position: Position(.nan, 0, 0)))])))
        XCTAssertThrowsError(try state.apply(.setCue(cue: Cue(number: "1", snapshot: UUID()))))
        XCTAssertThrowsError(try state.apply(.setCue(cue: Cue(number: "one"))))
        var clash = state.show.sources[0]
        clash.id = UUID()
        clash.number = 9
        XCTAssertThrowsError(try state.apply(.setSource(source: clash)), "two sources on one input")
        var group = state.show.groups[1]
        group.speakers.append(UUID())
        XCTAssertThrowsError(try state.apply(.setGroup(group: group)), "a speaker that does not exist")
        XCTAssertEqual(state, before)
    }

    func testWhatEachCommandNeedsRebuilt() throws {
        var state = try imported()
        let vox = state.show.sources[1]
        XCTAssertEqual(try state.apply(.updateSources(updates: [SourceUpdate(id: vox.id, values: SourceValues(width: 30))])), .sources([vox.id]))
        var renamed = vox
        renamed.name = "Lead"
        XCTAssertEqual(try state.apply(.setSource(source: renamed)), .sources([vox.id]))
        var moved = state.system.speakers[0]
        moved.position.x = -5
        XCTAssertEqual(try state.apply(.setSpeaker(speaker: moved)), .layout(crossfade: false))
        XCTAssertEqual(try state.apply(.removeGroup(id: state.show.groups[1].id)), .layout(crossfade: true))
        XCTAssertTrue(state.show.sources.allSatisfy { $0.sends.allSatisfy { s in state.group(s.group) != nil } },
                      "removing a group removes the sends to it")
        XCTAssertEqual(try state.apply(.renameShow(name: "x")), .none)
        try state.apply(.removeSpeaker(id: state.system.lfeSpeakers[0]))
        XCTAssertTrue(state.system.lfeSpeakers.isEmpty)
        XCTAssertNil(state.sourceConfig(state.show.sources[1]).lfeDB, "no LFE speakers, so no LFE send")
    }

    func testSnapshotsStoreOnlyTheirScope() throws {
        var state = try imported()
        let vox = state.show.sources[1].id, keys = state.show.sources[2].id
        try state.apply(.captureSnapshot(capture: SnapshotCapture(number: 1, name: "Pos", sources: [vox], fields: [.position, .mute])))
        let snap = try XCTUnwrap(state.show.snapshots.first)
        XCTAssertEqual(snap.sources.map(\.id), [vox])
        XCTAssertEqual(snap.sources[0].values, SourceValues(position: Position(-2, 1, 0), mute: false))
        // Storing again into the same id replaces it rather than adding one.
        try state.apply(.updateSources(updates: [SourceUpdate(id: vox, values: SourceValues(position: Position(0, 4, 0)))]))
        try state.apply(.captureSnapshot(capture: SnapshotCapture(id: snap.id, number: 1, name: "Pos", sources: [vox, keys])))
        XCTAssertEqual(state.show.snapshots.count, 1)
        XCTAssertEqual(state.show.snapshots[0].sources.count, 2)
        XCTAssertEqual(state.show.snapshots[0].sources[0].values.position, Position(0, 4, 0))
        XCTAssertEqual(state.show.snapshots[0].sources[1].values.lfeOff, true, "Keys has no LFE send, and the snapshot says so")
        // Removing the snapshot leaves its cues as markers.
        try state.apply(.setCue(cue: Cue(number: "1", snapshot: snap.id)))
        try state.apply(.removeSnapshot(id: snap.id))
        XCTAssertNil(state.show.cues[0].snapshot)
    }

    func testCuesRunInNumberOrder() throws {
        var state = try imported()
        for n in ["10", "2", "2.5", "1"] { try state.apply(.setCue(cue: Cue(number: n))) }
        XCTAssertEqual(state.orderedCues.map(\.number), ["1", "2", "2.5", "10"])
        XCTAssertEqual(state.cue(after: nil)?.number, "1")
        XCTAssertEqual(state.cue(after: state.cue(matching: "2.5")?.id)?.number, "10")
        XCTAssertNil(state.cue(after: state.cue(matching: "10")?.id))
        XCTAssertEqual(state.cue(matching: "2.50")?.number, "2.5")
        XCTAssertEqual(state.nextCueNumber, "11")
    }

    // MARK: Fades

    func testCurves() {
        for c in FadeCurve.allCases {
            XCTAssertEqual(c.apply(0), 0, accuracy: 1e-12)
            XCTAssertEqual(c.apply(1), 1, accuracy: 1e-12)
        }
        XCTAssertEqual(FadeCurve.linear.apply(0.25), 0.25)
        XCTAssertEqual(FadeCurve.sCurve.apply(0.5), 0.5, accuracy: 1e-12)
        XCTAssertLessThan(FadeCurve.sCurve.apply(0.1), 0.1)
        XCTAssertLessThan(FadeCurve.exponential.apply(0.5), 0.05)
    }

    func testAFadeMovesInAStraightLineAndEndsExactly() throws {
        var state = try imported()
        let vox = state.show.sources[1].id
        let main = state.show.groups[0].id, top = state.show.groups[1].id
        let snap = Snapshot(number: 1, name: "Across", fadeSeconds: 4, sources: [SourceUpdate(id: vox, values: SourceValues(
            position: Position(6, 9, 0), gainDB: -12, mute: false, sends: [GroupSend(group: top, gainDB: 0)], lfeOff: true))])
        try state.apply(.setSnapshot(snapshot: snap))
        try state.apply(.updateSources(updates: [SourceUpdate(id: vox, values: SourceValues(mute: true))]))
        let fade = SnapshotFade(snapshot: snap, state: state)
        XCTAssertEqual(fade.seconds, 4)

        let start = try XCTUnwrap(fade.updates(at: 0).first?.values)
        XCTAssertEqual(start.position, Position(-2, 1, 0))
        XCTAssertEqual(start.mute, false, "a source being unmuted unmutes at the start")

        let half = try XCTUnwrap(fade.updates(at: 2).first?.values)
        XCTAssertEqual(half.position, Position(2, 5, 0))
        XCTAssertEqual(half.gainDB, -6)
        // Main fades out towards the floor, Top fades in from it, both still present.
        XCTAssertEqual(half.sends?.first { $0.group == top }?.gainDB ?? 0, -30, accuracy: 1e-9)
        XCTAssertEqual(half.sends?.first { $0.group == main }?.gainDB ?? 0, -31, accuracy: 1e-9)
        XCTAssertEqual(half.lfeDB ?? 0, -33, accuracy: 1e-9)
        XCTAssertNil(half.width, "fields the snapshot does not store are left alone")

        let end = try XCTUnwrap(fade.updates(at: 5).first?.values)
        XCTAssertEqual(end, snap.sources[0].values)
        XCTAssertTrue(fade.isFinished(at: 4))
        try state.apply(.updateSources(updates: fade.updates(at: 5)))
        XCTAssertEqual(state.source(vox)?.sends, [GroupSend(group: top, gainDB: 0)])
        XCTAssertNil(state.source(vox)?.lfeDB)

        // A source being muted stays unmuted until the end.
        let mute = Snapshot(number: 2, name: "Out", fadeSeconds: 2, sources: [SourceUpdate(id: vox, values: SourceValues(mute: true))])
        let out = SnapshotFade(snapshot: mute, state: state)
        XCTAssertEqual(out.updates(at: 1).first?.values.mute, false)
        XCTAssertEqual(out.updates(at: 2).first?.values.mute, true)
    }

    func testAFadeLeavesOutSourcesThatAreGoneAndTakenOver() throws {
        var state = try imported()
        let ids = state.show.sources.map(\.id)
        let snap = Snapshot(number: 1, name: "All", fadeSeconds: 0, sources: ids.map {
            SourceUpdate(id: $0, values: SourceValues(gainDB: -1))
        } + [SourceUpdate(id: UUID(), values: SourceValues(gainDB: 0))])
        try state.apply(.removeSource(id: ids[2]))
        var fade = SnapshotFade(snapshot: snap, state: state, seconds: 3, curve: .linear)
        XCTAssertEqual(fade.sources, [ids[0], ids[1]])
        fade.remove([ids[0]])
        XCTAssertEqual(fade.updates(at: 3).map(\.id), [ids[1]])
        XCTAssertEqual(SnapshotFade(snapshot: snap, state: state).updates(at: 0).first?.values.gainDB, -1,
                       "a zero-time recall lands at once")
    }

    func testShowFilesFromANewerFeralAreRefused() {
        XCTAssertThrowsError(try JSONDecoder().decode(Show.self, from: Data(#"{"schema": 99, "name": "x"}"#.utf8)))
        XCTAssertNoThrow(try JSONDecoder().decode(Show.self, from: Data(#"{"name": "x"}"#.utf8)))
    }
}

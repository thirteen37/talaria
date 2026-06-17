import Foundation
import HermesKit
import Testing
@testable import Talaria

/// Covers the cold-relaunch persistence layer: the snapshot round-trips through a
/// temp file, equal snapshots skip the write, a missing/corrupt file decodes to
/// empty, distinct profiles don't collide, and the pure restore-selection decision
/// behaves.
@MainActor
@Suite
struct WindowRestorationStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowRestorationStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("window-restoration.json", isDirectory: false)
    }

    private func fullSnapshot() -> WindowRestorationSnapshot {
        WindowRestorationSnapshot(
            openSessionIds: ["sess-1", "sess-2"],
            openTitles: ["sess-1": "First chat", "sess-2": "Second chat"],
            selection: "sess-2",
            browse: BrowseDestination.extensions.rawValue,
            browseSubPath: [BrowseDestination.system.rawValue, BrowseDestination.models.rawValue],
            sheet: "browse"
        )
    }

    @Test
    func roundTripsAllFieldsThroughDisk() {
        let url = tempURL()
        let id = UUID()
        let snapshot = fullSnapshot()

        let store = WindowRestorationStore(fileURL: url)
        store.record(snapshot, for: id)

        // A fresh store reading the same file sees every field.
        let reloaded = WindowRestorationStore(fileURL: url)
        #expect(reloaded.snapshot(for: id) == snapshot)
    }

    @Test
    func recordSkipsWriteWhenSnapshotUnchanged() throws {
        let url = tempURL()
        let id = UUID()
        let snapshot = fullSnapshot()

        let store = WindowRestorationStore(fileURL: url)
        store.record(snapshot, for: id)
        #expect(FileManager.default.fileExists(atPath: url.path))

        // Delete the file, then re-record the identical snapshot: an equal value
        // is a no-op, so the file is NOT rewritten.
        try FileManager.default.removeItem(at: url)
        store.record(snapshot, for: id)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)

        // A genuinely changed snapshot does write again.
        var changed = snapshot
        changed.selection = "sess-1"
        store.record(changed, for: id)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func missingFileDecodesToEmpty() {
        let store = WindowRestorationStore(fileURL: tempURL())
        #expect(store.snapshot(for: UUID()) == nil)
    }

    @Test
    func corruptFileDecodesToEmpty() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: url)

        let store = WindowRestorationStore(fileURL: url)
        #expect(store.snapshot(for: UUID()) == nil)
    }

    @Test
    func snapshotDecodesWhenNewerFieldsAbsent() throws {
        // A snapshot persisted by a build without `openTitles` (or any other field)
        // must still decode, defaulting the missing fields, rather than failing.
        let json = #"{"openSessionIds":["s1"],"selection":"s1","browseSubPath":[]}"#
        let snap = try JSONDecoder().decode(WindowRestorationSnapshot.self, from: Data(json.utf8))
        #expect(snap.openSessionIds == ["s1"])
        #expect(snap.openTitles.isEmpty)
        #expect(snap.selection == "s1")
        #expect(snap.browse == nil)
        #expect(snap.sheet == nil)
    }

    @Test
    func distinctProfilesDoNotCollide() {
        let url = tempURL()
        let a = UUID()
        let b = UUID()
        let snapA = WindowRestorationSnapshot(openSessionIds: ["a"], selection: "a")
        let snapB = WindowRestorationSnapshot(openSessionIds: ["b"], selection: "b")

        let store = WindowRestorationStore(fileURL: url)
        store.record(snapA, for: a)
        store.record(snapB, for: b)

        let reloaded = WindowRestorationStore(fileURL: url)
        #expect(reloaded.snapshot(for: a) == snapA)
        #expect(reloaded.snapshot(for: b) == snapB)
    }

    // MARK: - Restore-selection decision

    @Test
    func resolvedSelectionKeepsRecordedWhenItReopened() {
        let selection = WindowRestoration.resolvedSelection(
            recorded: "sess-2",
            reopened: ["sess-1", "sess-2"]
        )
        #expect(selection == "sess-2")
    }

    @Test
    func resolvedSelectionFallsBackToFirstWhenRecordedMissing() {
        // The recorded selection 404'd (server-deleted), so it isn't among the
        // reopened ids — fall back to the first that did reopen.
        let selection = WindowRestoration.resolvedSelection(
            recorded: "gone",
            reopened: ["sess-1", "sess-2"]
        )
        #expect(selection == "sess-1")
    }

    @Test
    func resolvedSelectionNilWhenNothingReopened() {
        #expect(WindowRestoration.resolvedSelection(recorded: "sess-1", reopened: []) == nil)
    }

    @Test
    func resolvedSelectionNilWhenNoRecordedSelection() {
        // No recorded selection (Browse focused with tabs open) stays unselected —
        // restore must not auto-focus a tab the user wasn't viewing.
        let selection = WindowRestoration.resolvedSelection(
            recorded: nil,
            reopened: ["sess-1", "sess-2"]
        )
        #expect(selection == nil)
    }
}

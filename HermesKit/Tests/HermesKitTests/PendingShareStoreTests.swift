import Foundation
import Testing
@testable import HermesKit

@Suite
struct PendingShareStoreTests {
    /// Round-trips a text + two-image share through disk via a fresh reader
    /// instance — characterizes the staging contract the Share Extension and
    /// host app rely on.
    @Test
    func stagesAndReadsBackAcrossInstances() async throws {
        let container = makeTempContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let writer = PendingShareStore(containerURLOverride: container)
        let redBytes = Data([0xDE, 0xAD])
        let blueBytes = Data([0xBE, 0xEF, 0x00])
        let item = try await writer.stage(
            text: "hello from share",
            images: [(data: redBytes, mimeType: "image/png"), (data: blueBytes, mimeType: "image/jpeg")]
        )

        #expect(item.text == "hello from share")
        #expect(item.imageFiles.map(\.mimeType) == ["image/png", "image/jpeg"])
        #expect(Set(item.imageFiles.map(\.filename)).count == 2)

        let reader = PendingShareStore(containerURLOverride: container)
        // Compare meaningful fields; the manifest stores `createdAt` as ISO-8601
        // (second precision), so a strict whole-struct `==` would spuriously fail
        // on sub-second rounding — irrelevant to the hour-scale GC it feeds.
        let read = try #require(try await reader.pendingItem(id: item.id))
        #expect(read.id == item.id)
        #expect(read.text == item.text)
        #expect(read.imageFiles == item.imageFiles)
        #expect(abs(read.createdAt.timeIntervalSince(item.createdAt)) < 1)
        let loaded = try await reader.loadImageData(for: item)
        #expect(loaded.map(\.data) == [redBytes, blueBytes])
    }

    /// `consume` deletes the share; a subsequent read returns nil.
    @Test
    func consumeRemovesTheShare() async throws {
        let container = makeTempContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let store = PendingShareStore(containerURLOverride: container)
        let item = try await store.stage(text: "bye", images: [])
        try await store.consume(id: item.id)
        #expect(try await store.pendingItem(id: item.id) == nil)
    }

    /// Reading an id that was never staged returns nil, not an error.
    @Test
    func readingUnknownIdReturnsNil() async throws {
        let container = makeTempContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let store = PendingShareStore(containerURLOverride: container)
        #expect(try await store.pendingItem(id: UUID()) == nil)
    }

    /// The manifest's own `createdAt` takes precedence over the directory's
    /// filesystem date: a share with a fresh manifest survives pruning even
    /// when the directory's fs timestamp has been backdated past the cutoff.
    @Test
    func pruneStaleKeepsFreshManifestShares() async throws {
        let container = makeTempContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let store = PendingShareStore(containerURLOverride: container)
        let item = try await store.stage(text: "fresh", images: [])
        // Backdate the directory's fs timestamp — but the manifest's createdAt
        // stays "now", so the manifest-date path must keep the share.
        let root = container.appendingPathComponent("PendingShares", isDirectory: true)
        let itemDir = root.appendingPathComponent(item.id.uuidString, isDirectory: true)
        try backdate(itemDir, by: 3600)

        try await store.pruneStale(olderThan: 60)
        #expect(try await store.pendingItem(id: item.id) != nil)
    }

    /// The store's primary GC behavior: a share whose *manifest* `createdAt` is
    /// past the cutoff is deleted. Ages the manifest itself (not just the fs
    /// timestamp) by rewriting it with an old date in the store's own encoding.
    @Test
    func pruneStaleDropsSharesWhoseManifestDateIsPastCutoff() async throws {
        let container = makeTempContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let store = PendingShareStore(containerURLOverride: container)
        let item = try await store.stage(text: "old", images: [])

        let root = container.appendingPathComponent("PendingShares", isDirectory: true)
        let manifestURL = root.appendingPathComponent(item.id.uuidString, isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)
        let aged = PendingShareItem(
            id: item.id,
            createdAt: Date().addingTimeInterval(-3600),
            text: item.text,
            imageFiles: item.imageFiles
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(aged).write(to: manifestURL, options: [.atomic])

        try await store.pruneStale(olderThan: 60)
        #expect(try await store.pendingItem(id: item.id) == nil)
    }

    /// Regression for the orphan-GC gap: `stage()` writes image files first and
    /// the manifest last, so an extension killed mid-write (the exact force-quit
    /// case `pruneStale` documents cleaning up) leaves a manifest-less directory.
    /// That orphan must still be collected once it ages past the cutoff, else it
    /// accumulates in the App Group container forever.
    @Test
    func pruneStaleCollectsManifestlessOrphansPastCutoff() async throws {
        let container = makeTempContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let store = PendingShareStore(containerURLOverride: container)
        let fresh = try await store.stage(text: "keep me", images: [])

        // Simulate an interrupted stage: an image written, manifest never was.
        let root = container.appendingPathComponent("PendingShares", isDirectory: true)
        let orphan = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data([0x00, 0x01]).write(to: orphan.appendingPathComponent("image-0.dat", isDirectory: false))
        try backdate(orphan, by: 3600)

        try await store.pruneStale(olderThan: 60)

        #expect(FileManager.default.fileExists(atPath: orphan.path) == false,
                "aged manifest-less orphan should be collected")
        #expect(try await store.pendingItem(id: fresh.id) != nil,
                "a fresh valid share must survive pruning")
    }

    /// A manifest-less directory that is still *fresh* (an in-flight stage on
    /// another thread) must NOT be collected.
    @Test
    func pruneStaleKeepsFreshManifestlessDirectories() async throws {
        let container = makeTempContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let store = PendingShareStore(containerURLOverride: container)
        _ = try await store.stage(text: "root", images: [])
        let root = container.appendingPathComponent("PendingShares", isDirectory: true)
        let inFlight = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: inFlight, withIntermediateDirectories: true)
        try Data([0x02]).write(to: inFlight.appendingPathComponent("image-0.dat", isDirectory: false))

        try await store.pruneStale(olderThan: 3600)
        #expect(FileManager.default.fileExists(atPath: inFlight.path) == true,
                "a just-created (in-flight) manifest-less directory must survive")
    }

    // MARK: - Helpers

    private func backdate(_ url: URL, by seconds: TimeInterval) throws {
        let old = Date().addingTimeInterval(-seconds)
        try FileManager.default.setAttributes(
            [.modificationDate: old, .creationDate: old],
            ofItemAtPath: url.path
        )
    }

    private func makeTempContainer() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingShareStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

import Foundation
import Testing
@testable import HermesKit

@Suite
struct ProfileStoreTests {
    @Test
    func roundTripsProfilesAcrossInstances() async throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = ProfileStore(url: url)
        let profileA = ServerProfile(name: "Box A", kind: .ssh, host: "a.example.com", user: "x")
        let profileB = ServerProfile(name: "Box B", kind: .local)
        try await first.upsert(profileA)
        try await first.upsert(profileB)

        let second = ProfileStore(url: url)
        let loaded = try await second.all()
        let ids = Set(loaded.map(\.id))
        #expect(ids == Set([profileA.id, profileB.id]))
    }

    @Test
    func upsertUpdatesExistingProfile() async throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ProfileStore(url: url)
        var profile = ServerProfile(name: "Initial", kind: .ssh, host: "a")
        try await store.upsert(profile)
        profile.name = "Renamed"
        try await store.upsert(profile)
        let loaded = try await store.all()
        #expect(loaded.count == 1)
        #expect(loaded.first?.name == "Renamed")
    }

    @Test
    func duplicateProducesUniqueNameAndId() async throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ProfileStore(url: url)
        let original = ServerProfile(name: "Origin", kind: .ssh, host: "h")
        try await store.upsert(original)
        let firstCopy = try await store.duplicate(id: original.id)
        let secondCopy = try await store.duplicate(id: original.id)

        #expect(firstCopy.id != original.id)
        #expect(secondCopy.id != firstCopy.id)
        #expect(firstCopy.name == "Origin Copy")
        #expect(secondCopy.name == "Origin Copy 2")
    }

    @Test
    func deleteRemovesProfile() async throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ProfileStore(url: url)
        let profile = ServerProfile(name: "Disposable", kind: .ssh)
        try await store.upsert(profile)
        try await store.delete(id: profile.id)
        let remaining = try await store.all()
        #expect(remaining.isEmpty)
    }

    @Test
    func loadReturnsEmptyWhenFileMissing() async throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ProfileStore(url: url)
        let result = try await store.load()
        #expect(result.isEmpty)
    }

    private func tmpURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesKit-ProfileStoreTests-\(UUID().uuidString)", isDirectory: true)
        return dir.appendingPathComponent("profiles.json", isDirectory: false)
    }
}

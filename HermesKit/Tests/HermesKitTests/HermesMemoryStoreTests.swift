import Foundation
import Testing
@testable import HermesKit

@Suite
struct HermesMemoryStoreTests {
    // MARK: - File metadata

    @Test
    func fileNamesAndCaps() {
        #expect(HermesMemoryFile.memory.fileName == "MEMORY.md")
        #expect(HermesMemoryFile.user.fileName == "USER.md")
        #expect(HermesMemoryFile.memory.charCap == 2200)
        #expect(HermesMemoryFile.user.charCap == 1375)
    }

    // MARK: - relativePath

    @Test
    func relativePathForDefaultProfile() {
        #expect(HermesMemoryStore.relativePath(profileName: "default", file: .memory) == "memories/MEMORY.md")
        #expect(HermesMemoryStore.relativePath(profileName: "default", file: .user) == "memories/USER.md")
    }

    @Test
    func relativePathForNamedProfile() {
        #expect(HermesMemoryStore.relativePath(profileName: "work", file: .memory) == "profiles/work/memories/MEMORY.md")
        #expect(HermesMemoryStore.relativePath(profileName: "work", file: .user) == "profiles/work/memories/USER.md")
    }

    // MARK: - Local read/write

    @Test
    func localWriteThenReadRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = ServerProfile(name: "Local", kind: .local, hermesHome: dir.path)

        try await HermesMemoryStore.write("# Memory\n", profile: profile, profileName: "default", file: .memory)
        let read = try await HermesMemoryStore.read(profile: profile, profileName: "default", file: .memory)
        #expect(read == "# Memory\n")

        let onDisk = dir.appendingPathComponent("memories/MEMORY.md")
        #expect(FileManager.default.fileExists(atPath: onDisk.path))
    }

    @Test
    func readMissingFileReturnsEmpty() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = ServerProfile(name: "Local", kind: .local, hermesHome: dir.path)

        // A fresh install with no memories yet reads as empty, not an error.
        let read = try await HermesMemoryStore.read(profile: profile, profileName: "default", file: .user)
        #expect(read.isEmpty)
    }
}

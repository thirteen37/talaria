import Foundation
import Testing
@testable import HermesKit

@Suite
struct HermesFileStoreTests {
    // MARK: - Local

    @Test
    func localWriteThenReadRoundTrip() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = ServerProfile(name: "Local", kind: .local, hermesHome: dir.path)

        try await HermesFileStore.write(
            "hello memory",
            profile: profile,
            location: .profileRelative(tail: "memories/MEMORY.md"),
            transfer: nil
        )

        // Written under the resolved home, creating the memories/ dir.
        let onDisk = dir.appendingPathComponent("memories/MEMORY.md")
        #expect(FileManager.default.fileExists(atPath: onDisk.path))

        let read = try await HermesFileStore.read(
            profile: profile,
            location: .profileRelative(tail: "memories/MEMORY.md"),
            transfer: nil
        )
        #expect(read == "hello memory")
    }

    @Test
    func localWriteNamedProfilePath() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = ServerProfile(name: "Local", kind: .local, hermesHome: dir.path)

        try await HermesFileStore.write(
            "scoped",
            profile: profile,
            location: .profileRelative(tail: "profiles/work/memories/USER.md"),
            transfer: nil
        )

        let onDisk = dir.appendingPathComponent("profiles/work/memories/USER.md")
        #expect(try String(contentsOf: onDisk, encoding: .utf8) == "scoped")
    }

    @Test
    func localReadMissingThrowsNotFound() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = ServerProfile(name: "Local", kind: .local, hermesHome: dir.path)

        await #expect(throws: HermesFileStoreError.self) {
            _ = try await HermesFileStore.read(
                profile: profile,
                location: .profileRelative(tail: "memories/MEMORY.md"),
                transfer: nil
            )
        }
    }

    @Test
    func resolvedLocalReadExpandsAndReads() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("custom.env")
        try "A=1\n".write(to: file, atomically: true, encoding: .utf8)

        let read = try await HermesFileStore.read(
            resolvedPath: file.path,
            isLocal: true,
            transfer: nil,
            profile: nil
        )
        #expect(read == "A=1\n")
    }

    // MARK: - Remote (via stub transfer)

    @Test
    func remoteWriteThenReadRoundTrip() async throws {
        let stub = RecordingTransfer()
        let profile = ServerProfile(name: "Remote", kind: .ssh, host: "host", user: "u")

        try await HermesFileStore.write(
            "remote body",
            profile: profile,
            location: .profileRelative(tail: "memories/MEMORY.md"),
            transfer: stub
        )

        // Default profile, nil home → home-relative `.hermes/...`.
        #expect(stub.uploadedPaths == [".hermes/memories/MEMORY.md"])

        let read = try await HermesFileStore.read(
            profile: profile,
            location: .profileRelative(tail: "memories/MEMORY.md"),
            transfer: stub
        )
        #expect(read == "remote body")
        #expect(stub.fetchedPaths == [".hermes/memories/MEMORY.md"])
    }

    @Test
    func remoteReadMissingThrowsNotFound() async {
        let stub = RecordingTransfer()
        let profile = ServerProfile(name: "Remote", kind: .ssh, host: "host", user: "u")

        await #expect(throws: HermesFileStoreError.self) {
            _ = try await HermesFileStore.read(
                profile: profile,
                location: .profileRelative(tail: "memories/MEMORY.md"),
                transfer: stub
            )
        }
    }

    @Test
    func remoteTransferUnavailableWhenNoTransferOrProfile() async {
        // No injected transfer and no profile → can't build a fallback, even on
        // macOS (the SFTP fallback needs a profile to construct).
        await #expect(throws: HermesFileStoreError.transferUnavailable) {
            _ = try await HermesFileStore.read(
                resolvedPath: "/home/u/.hermes/memories/MEMORY.md",
                isLocal: false,
                transfer: nil,
                profile: nil
            )
        }
    }

    // MARK: - Helpers

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// In-memory `RemoteSnapshotTransfer` for the store tests: `upload` stashes the
/// file contents keyed by remote path; `fetch` serves them back (or raises a
/// "No such file" transfer error for an unknown path, matching the real
/// transports' missing-file wording).
final class RecordingTransfer: RemoteSnapshotTransfer, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: String] = [:]
    private var _uploadedPaths: [String] = []
    private var _fetchedPaths: [String] = []

    var uploadedPaths: [String] { lock.withLock { _uploadedPaths } }
    var fetchedPaths: [String] { lock.withLock { _fetchedPaths } }

    func fetch(remotePath: String, to: URL) async throws {
        let contents: String? = lock.withLock {
            _fetchedPaths.append(remotePath)
            return store[remotePath]
        }
        guard let contents else {
            throw SSHTransportError.transferFailed("No such file or directory")
        }
        try contents.write(to: to, atomically: true, encoding: .utf8)
    }

    func upload(from localURL: URL, to remotePath: String) async throws {
        let contents = try String(contentsOf: localURL, encoding: .utf8)
        lock.withLock {
            _uploadedPaths.append(remotePath)
            store[remotePath] = contents
        }
    }
}

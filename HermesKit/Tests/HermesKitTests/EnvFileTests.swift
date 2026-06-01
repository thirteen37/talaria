import Foundation
import Testing
@testable import HermesKit

@Suite
struct EnvFileTests {
    // MARK: - parse

    @Test
    func parseReadsSimpleKeyValue() {
        let entries = EnvFile.parse("MY_API_BASE=https://example.com")
        #expect(entries == [EnvFileEntry(key: "MY_API_BASE", value: "https://example.com")])
    }

    @Test
    func parseStripsSurroundingDoubleAndSingleQuotes() {
        // Mirror Hermes `value.strip().strip("\"'")`: a char-set trim of any
        // surrounding run of " / ' — not a single layer.
        let entries = EnvFile.parse(
            """
            DQ="quoted"
            SQ='quoted'
            MIXED="'quoted'"
            """
        )
        #expect(entries == [
            EnvFileEntry(key: "DQ", value: "quoted"),
            EnvFileEntry(key: "SQ", value: "quoted"),
            EnvFileEntry(key: "MIXED", value: "quoted"),
        ])
    }

    @Test
    func parseKeepsEqualsInsideValue() {
        // Split on the FIRST `=` only; the rest stays in the value.
        let entries = EnvFile.parse("DB_URL=postgres://u:p@h/db?a=1&b=2")
        #expect(entries == [EnvFileEntry(key: "DB_URL", value: "postgres://u:p@h/db?a=1&b=2")])
    }

    @Test
    func parseSkipsCommentsBlanksAndNonAssignments() {
        let entries = EnvFile.parse(
            """
            # a comment
            KEEP=1

               # indented comment
            NOT_AN_ASSIGNMENT
            ALSO_KEEP=2
            """
        )
        #expect(entries == [
            EnvFileEntry(key: "KEEP", value: "1"),
            EnvFileEntry(key: "ALSO_KEEP", value: "2"),
        ])
    }

    @Test
    func parseTrimsWhitespaceAroundKeyAndValue() {
        let entries = EnvFile.parse("   PADDED   =   spaced value   ")
        #expect(entries == [EnvFileEntry(key: "PADDED", value: "spaced value")])
    }

    @Test
    func parsePreservesOrder() {
        let entries = EnvFile.parse(
            """
            C=3
            A=1
            B=2
            """
        )
        #expect(entries.map(\.key) == ["C", "A", "B"])
    }

    @Test
    func parseHandlesCRLFLineEndings() {
        let entries = EnvFile.parse("A=1\r\nB=2\r\n")
        #expect(entries == [
            EnvFileEntry(key: "A", value: "1"),
            EnvFileEntry(key: "B", value: "2"),
        ])
    }

    // MARK: - redactEnvValue

    @Test
    func redactEnvValueEmptyReturnsEmpty() {
        #expect(redactEnvValue("") == "")
    }

    @Test
    func redactEnvValueShortIsFullyMasked() {
        // < 12 chars → placeholder, mirroring Hermes `mask_secret` floor.
        #expect(redactEnvValue("short") == "***")
        #expect(redactEnvValue("11characters") != "***") // 12 chars is not short
    }

    @Test
    func redactEnvValueLongKeepsPrefixAndSuffix() {
        #expect(redactEnvValue("sk-proj-abcdef1234567890") == "sk-p...7890")
    }

    // MARK: - HermesEnvFileReader (local)

    @Test
    func readerLocalReadsEnvPathFromRunner() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-envfile-\(UUID().uuidString).env")
        try "FOO=bar\nBAZ=qux\n".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let runner = StubEnvPathRunner(envPath: tmp.path)
        let reader = HermesEnvFileReader(runner: runner, snapshotTransfer: nil, isLocal: true)

        let entries = try await reader.read()

        #expect(entries == [
            EnvFileEntry(key: "FOO", value: "bar"),
            EnvFileEntry(key: "BAZ", value: "qux"),
        ])
        #expect(runner.commands == [["config", "env-path"]])
    }

    @Test
    func readerLocalReturnsEmptyWhenFileMissing() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-missing-\(UUID().uuidString).env")
        let runner = StubEnvPathRunner(envPath: missing.path)
        let reader = HermesEnvFileReader(runner: runner, snapshotTransfer: nil, isLocal: true)

        let entries = try await reader.read()

        #expect(entries.isEmpty)
    }

    @Test
    func readerThrowsWhenRunnerUnavailable() async {
        let reader = HermesEnvFileReader(runner: nil, snapshotTransfer: nil, isLocal: true)
        await #expect(throws: EnvFileError.self) {
            _ = try await reader.read()
        }
    }

    @Test
    func readerThrowsWhenEnvPathBlank() async {
        let runner = StubEnvPathRunner(envPath: "   ")
        let reader = HermesEnvFileReader(runner: runner, snapshotTransfer: nil, isLocal: true)
        await #expect(throws: EnvFileError.self) {
            _ = try await reader.read()
        }
    }

    // MARK: - HermesEnvFileReader (remote)

    @Test
    func readerRemoteFetchesViaSnapshotTransfer() async throws {
        let runner = StubEnvPathRunner(envPath: "/home/u/.hermes/.env")
        let transfer = StubSnapshotTransfer(contents: "REMOTE_KEY=remote-value\n")
        let reader = HermesEnvFileReader(runner: runner, snapshotTransfer: transfer, isLocal: false)

        let entries = try await reader.read()

        #expect(entries == [EnvFileEntry(key: "REMOTE_KEY", value: "remote-value")])
        #expect(transfer.requestedPaths == ["/home/u/.hermes/.env"])
    }

    @Test
    func readerRemoteThrowsWhenTransferUnavailable() async {
        let runner = StubEnvPathRunner(envPath: "/home/u/.hermes/.env")
        let reader = HermesEnvFileReader(runner: runner, snapshotTransfer: nil, isLocal: false)
        await #expect(throws: EnvFileError.self) {
            _ = try await reader.read()
        }
    }

    @Test(arguments: [
        // `cat` (NIO) and modern OpenSSH `sftp` both phrase it this way…
        "Couldn't stat remote file: No such file or directory",
        // …while some SFTP servers emit an alternate "not found" wording.
        "File \"/home/u/.hermes/.env\" not found.",
    ])
    func readerRemoteTreatsMissingFileAsEmpty(message: String) async throws {
        let runner = StubEnvPathRunner(envPath: "/home/u/.hermes/.env")
        let transfer = StubThrowingTransfer(error: .transferFailed(message))
        let reader = HermesEnvFileReader(runner: runner, snapshotTransfer: transfer, isLocal: false)

        // Mirrors the local missing-file path: a fresh-install host with no
        // `.env` yet reads as "no custom vars", not a persistent error banner.
        let entries = try await reader.read()
        #expect(entries.isEmpty)
    }

    @Test
    func readerRemoteSurfacesNonMissingTransferError() async {
        let runner = StubEnvPathRunner(envPath: "/home/u/.hermes/.env")
        let transfer = StubThrowingTransfer(error: .transferFailed("Permission denied"))
        let reader = HermesEnvFileReader(runner: runner, snapshotTransfer: transfer, isLocal: false)

        // A real transfer failure (not a missing file) must still surface.
        await #expect(throws: EnvFileError.self) {
            _ = try await reader.read()
        }
    }
}

// MARK: - Stubs

/// One-shot `HermesAdminRunning` that returns a fixed `config env-path` stdout
/// and records the argv it was asked to run.
private final class StubEnvPathRunner: HermesAdminRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [[String]] = []
    private let envPath: String

    init(envPath: String) {
        self.envPath = envPath
    }

    var commands: [[String]] { lock.withLock { _commands } }

    func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult {
        lock.withLock { _commands.append(command.arguments) }
        return HermesAdminResult(exitCode: 0, stdout: envPath + "\n", stderr: "")
    }
}

/// `RemoteSnapshotTransfer` that writes fixed bytes to the `to:` URL and records
/// the remote paths it was asked to fetch.
private final class StubSnapshotTransfer: RemoteSnapshotTransfer, @unchecked Sendable {
    private let lock = NSLock()
    private var _requestedPaths: [String] = []
    private let contents: String

    init(contents: String) {
        self.contents = contents
    }

    var requestedPaths: [String] { lock.withLock { _requestedPaths } }

    func fetch(remotePath: String, to: URL) async throws {
        lock.withLock { _requestedPaths.append(remotePath) }
        try contents.write(to: to, atomically: true, encoding: .utf8)
    }
}

/// `RemoteSnapshotTransfer` that always fails the fetch with a fixed error —
/// exercises ``HermesEnvFileReader``'s missing-file vs. real-error handling.
private struct StubThrowingTransfer: RemoteSnapshotTransfer {
    let error: SSHTransportError
    func fetch(remotePath: String, to: URL) async throws { throw error }
}

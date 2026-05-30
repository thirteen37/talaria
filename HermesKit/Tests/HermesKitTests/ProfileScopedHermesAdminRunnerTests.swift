import Foundation
import Testing
@testable import HermesKit

/// Records the arguments each command was run/streamed with so the decorator's
/// `-p` injection can be verified without a real hermes process.
private final class RecordingAdminRunner: HermesAdminRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _runArguments: [[String]] = []
    private var _streamArguments: [[String]] = []

    var runArguments: [[String]] { lock.withLock { _runArguments } }
    var streamArguments: [[String]] { lock.withLock { _streamArguments } }

    func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult {
        lock.withLock { _runArguments.append(command.arguments) }
        return HermesAdminResult(exitCode: 0, stdout: "", stderr: "")
    }

    func runStream(_ command: HermesAdminCommand) -> AsyncThrowingStream<AdminEvent, Error> {
        lock.withLock { _streamArguments.append(command.arguments) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.exit(0))
            continuation.finish()
        }
    }
}

@Suite
struct ProfileScopedHermesAdminRunnerTests {
    @Test
    func defaultProfilePassesCommandThroughUnscoped() async throws {
        let inner = RecordingAdminRunner()
        let runner = ProfileScopedHermesAdminRunner(
            inner: inner,
            hermesProfileName: HermesProfiles.defaultProfileName
        )

        _ = try await runner.run(HermesAdminCommand(arguments: ["tools", "list"]))

        #expect(inner.runArguments == [["tools", "list"]])
    }

    @Test
    func namedProfilePrependsGlobalProfileFlag() async throws {
        let inner = RecordingAdminRunner()
        let runner = ProfileScopedHermesAdminRunner(inner: inner, hermesProfileName: "work")

        _ = try await runner.run(HermesAdminCommand(arguments: ["tools", "list"]))

        // `-p work` is global, so it precedes the subcommand.
        #expect(inner.runArguments == [["-p", "work", "tools", "list"]])
    }

    @Test
    func profileSubcommandStaysUnscopedEvenForNamedProfile() async throws {
        let inner = RecordingAdminRunner()
        let runner = ProfileScopedHermesAdminRunner(inner: inner, hermesProfileName: "work")

        _ = try await runner.run(HermesAdminCommand(arguments: ["profile", "list"]))

        // `profile list` must enumerate every profile — scoping it to one would
        // be wrong, so it passes through untouched.
        #expect(inner.runArguments == [["profile", "list"]])
    }

    @Test
    func runStreamIsScopedToo() async throws {
        let inner = RecordingAdminRunner()
        let runner = ProfileScopedHermesAdminRunner(inner: inner, hermesProfileName: "work")

        for try await _ in runner.runStream(HermesAdminCommand(arguments: ["doctor"])) {}

        #expect(inner.streamArguments == [["-p", "work", "doctor"]])
    }
}

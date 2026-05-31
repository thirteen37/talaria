import Foundation
import Testing
@testable import HermesKit

/// Records every command's argv so `HermesGateway` lifecycle builders can be
/// verified without spawning a real hermes process. Returns a canned result
/// (success by default, or a configured failure).
private final class RecordingAdminRunner: HermesAdminRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _arguments: [[String]] = []
    private let result: HermesAdminResult

    init(result: HermesAdminResult = HermesAdminResult(exitCode: 0, stdout: "", stderr: "")) {
        self.result = result
    }

    var arguments: [[String]] { lock.withLock { _arguments } }

    func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult {
        lock.withLock { _arguments.append(command.arguments) }
        return result
    }

    func runStream(_ command: HermesAdminCommand) -> AsyncThrowingStream<AdminEvent, Error> {
        lock.withLock { _arguments.append(command.arguments) }
        return AsyncThrowingStream { $0.finish() }
    }
}

@Suite
struct HermesGatewayTests {
    // MARK: - Lifecycle argv

    @Test
    func startBuildsStartArgv() async throws {
        let runner = RecordingAdminRunner()
        try await HermesGateway.start(runner: runner)
        #expect(runner.arguments == [["gateway", "start"]])
    }

    @Test
    func stopBuildsStopArgv() async throws {
        let runner = RecordingAdminRunner()
        try await HermesGateway.stop(runner: runner)
        #expect(runner.arguments == [["gateway", "stop"]])
    }

    @Test
    func restartBuildsRestartArgv() async throws {
        let runner = RecordingAdminRunner()
        try await HermesGateway.restart(runner: runner)
        #expect(runner.arguments == [["gateway", "restart"]])
    }

    @Test
    func installBuildsInstallArgv() async throws {
        // `hermes gateway install` has no interactive prompt (verified against
        // `--help`: only `--force` / `--system` / `--run-as-user`), so the bare
        // verb is non-interactive on its own.
        let runner = RecordingAdminRunner()
        try await HermesGateway.install(runner: runner)
        #expect(runner.arguments == [["gateway", "install"]])
    }

    @Test
    func uninstallBuildsUninstallArgv() async throws {
        // `hermes gateway uninstall` exposes no `--yes`/`-y` flag (only
        // `--system`); it does not prompt, so the bare verb is correct and the
        // UI supplies its own destructive confirmation.
        let runner = RecordingAdminRunner()
        try await HermesGateway.uninstall(runner: runner)
        #expect(runner.arguments == [["gateway", "uninstall"]])
    }

    // MARK: - ensureSuccess mapping

    @Test
    func mapsUnknownCommandToCommandUnavailable() async throws {
        let runner = RecordingAdminRunner(
            result: HermesAdminResult(exitCode: 2, stdout: "", stderr: "hermes: no such command 'gateway'\n")
        )
        do {
            try await HermesGateway.start(runner: runner)
            #expect(Bool(false), "expected commandUnavailable to be thrown")
        } catch let error as HermesGatewayError {
            guard case .commandUnavailable = error else {
                #expect(Bool(false), "expected commandUnavailable, got \(error)")
                return
            }
        }
    }

    @Test
    func mapsNonZeroExitToCommandFailed() async throws {
        let runner = RecordingAdminRunner(
            result: HermesAdminResult(exitCode: 1, stdout: "", stderr: "Gateway service is not installed\n")
        )
        do {
            try await HermesGateway.start(runner: runner)
            #expect(Bool(false), "expected commandFailed to be thrown")
        } catch let error as HermesGatewayError {
            guard case .commandFailed(let code, _) = error else {
                #expect(Bool(false), "expected commandFailed, got \(error)")
                return
            }
            #expect(code == 1)
        }
    }

    @Test
    func ensureSuccessDoesNotSwallowEnvBinaryNotFound() {
        let result = HermesAdminResult(exitCode: 127, stdout: "", stderr: "env: hermes: No such file or directory\n")
        do {
            try HermesGateway.ensureSuccess(result)
            #expect(Bool(false), "ensureSuccess should have thrown")
        } catch let error as HermesGatewayError {
            if case .commandFailed = error {} else {
                #expect(Bool(false), "expected commandFailed, got \(error)")
            }
        } catch {
            #expect(Bool(false), "unexpected error type \(error)")
        }
    }
}

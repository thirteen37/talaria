import Foundation
import Testing
@testable import HermesKit

@Suite
struct DashboardSupervisorTests {
    @Test
    func firstAcquireSpawnsProcessAndWaitsForReachability() async throws {
        let launcher = StubLauncher()
        let http = StubHTTP(responses: [
            // /api/status reachability probe — supervisor polls here until 200
            .init(path: "/api/status", body: Data(#"{"version":"0.14.0"}"#.utf8)),
            // Token scrape on first DashboardSession.refresh()
            .init(path: "/", body: Data(makeSPAHTML(token: "T").utf8))
        ])
        let supervisor = DashboardSupervisor(
            profile: ServerProfile(name: "L", kind: .local, hermesPath: "/bin/hermes"),
            launcher: launcher,
            http: http,
            portAllocator: { 51919 }
        )

        let endpoint = try await supervisor.acquire()

        #expect(launcher.launchedSpecs.count == 1)
        #expect(endpoint.baseURL.absoluteString == "http://127.0.0.1:51919")
        // Session has the token cached (refresh ran during acquire so consumers
        // can immediately hit authenticated routes without an extra round-trip).
        #expect(endpoint.session.tokenSnapshot() == "T")
    }

    @Test
    func concurrentAcquiresCoalesceIntoOneSpawn() async throws {
        // Two acquirers fire simultaneously while `current` is nil. Without
        // task coalescing the actor's reentrancy lets each call see nil
        // after `spawnAndReady` suspends, spawning two processes and
        // leaking the first.
        let launcher = StubLauncher()
        let http = StubHTTP(responses: [
            .init(path: "/api/status", body: Data(#"{"version":"0.14.0"}"#.utf8)),
            .init(path: "/", body: Data(makeSPAHTML(token: "T").utf8))
        ])
        let supervisor = DashboardSupervisor(
            profile: ServerProfile(name: "L", kind: .local, hermesPath: "/bin/hermes"),
            launcher: launcher,
            http: http,
            portAllocator: { 51919 }
        )

        async let first = supervisor.acquire()
        async let second = supervisor.acquire()
        let (a, b) = try await (first, second)

        #expect(launcher.launchedSpecs.count == 1)
        #expect(a.baseURL == b.baseURL)
        #expect(launcher.lastSpawnedProcess?.terminatedCount.value == 0)
        await supervisor.release()
        #expect(launcher.lastSpawnedProcess?.terminatedCount.value == 0)
        await supervisor.release()
        #expect(launcher.lastSpawnedProcess?.terminatedCount.value == 1)
    }

    @Test
    func subsequentAcquiresShareTheSpawnedProcess() async throws {
        let launcher = StubLauncher()
        let http = StubHTTP(responses: [
            .init(path: "/api/status", body: Data(#"{"version":"0.14.0"}"#.utf8)),
            .init(path: "/", body: Data(makeSPAHTML(token: "T").utf8))
        ])
        let supervisor = DashboardSupervisor(
            profile: ServerProfile(name: "L", kind: .local, hermesPath: "/bin/hermes"),
            launcher: launcher,
            http: http,
            portAllocator: { 51919 }
        )

        let first = try await supervisor.acquire()
        let second = try await supervisor.acquire()

        #expect(launcher.launchedSpecs.count == 1)
        #expect(first.baseURL == second.baseURL)
    }

    @Test
    func releaseToZeroTerminatesTheProcess() async throws {
        let launcher = StubLauncher()
        let http = StubHTTP(responses: [
            .init(path: "/api/status", body: Data(#"{"version":"0.14.0"}"#.utf8)),
            .init(path: "/", body: Data(makeSPAHTML(token: "T").utf8))
        ])
        let supervisor = DashboardSupervisor(
            profile: ServerProfile(name: "L", kind: .local, hermesPath: "/bin/hermes"),
            launcher: launcher,
            http: http,
            portAllocator: { 51919 }
        )

        _ = try await supervisor.acquire()
        _ = try await supervisor.acquire()
        await supervisor.release()
        // Refcount still 1 — process must remain running.
        #expect(launcher.lastSpawnedProcess?.terminatedCount.value == 0)
        await supervisor.release()
        #expect(launcher.lastSpawnedProcess?.terminatedCount.value == 1)
    }

    @Test
    func acquireAfterFullReleaseSpawnsAgain() async throws {
        let launcher = StubLauncher()
        let http = StubHTTP(responses: [
            // First acquire
            .init(path: "/api/status", body: Data(#"{"version":"0.14.0"}"#.utf8)),
            .init(path: "/", body: Data(makeSPAHTML(token: "T1").utf8)),
            // Second acquire after release
            .init(path: "/api/status", body: Data(#"{"version":"0.14.0"}"#.utf8)),
            .init(path: "/", body: Data(makeSPAHTML(token: "T2").utf8)),
        ])
        let supervisor = DashboardSupervisor(
            profile: ServerProfile(name: "L", kind: .local, hermesPath: "/bin/hermes"),
            launcher: launcher,
            http: http,
            portAllocator: { 51919 }
        )

        _ = try await supervisor.acquire()
        await supervisor.release()
        _ = try await supervisor.acquire()

        #expect(launcher.launchedSpecs.count == 2)
    }

    @Test
    func releaseDuringPendingAcquireTerminatesSpawnWhenItBecomesReady() async throws {
        let launcher = StubLauncher()
        let http = StubHTTP(responses: [])
        let supervisor = DashboardSupervisor(
            profile: ServerProfile(name: "L", kind: .local, hermesPath: "/bin/hermes"),
            launcher: launcher,
            http: http,
            portAllocator: { 51919 },
            reachabilityTimeout: 5.0,
            reachabilityPollInterval: 0.01
        )

        let acquireTask = Task {
            try await supervisor.acquire()
        }
        while launcher.launchedSpecs.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        await supervisor.release()

        do {
            _ = try await acquireTask.value
            Issue.record("Expected pending acquire to be cancelled")
        } catch is CancellationError {
            // Expected: teardown released the only pending consumer.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(launcher.lastSpawnedProcess?.terminatedCount.value == 1)
    }

    @Test
    func acquireFailsWhenStatusNeverBecomesReachable() async throws {
        let launcher = StubLauncher()
        // No /api/status response — every probe returns the URLError default.
        let http = StubHTTP(responses: [])
        let supervisor = DashboardSupervisor(
            profile: ServerProfile(name: "L", kind: .local, hermesPath: "/bin/hermes"),
            launcher: launcher,
            http: http,
            portAllocator: { 51919 },
            reachabilityTimeout: 0.1,
            reachabilityPollInterval: 0.02
        )

        await #expect(throws: DashboardSupervisorError.notReachable) {
            _ = try await supervisor.acquire()
        }
        // Failed startup must also terminate the process so we don't leak
        // an orphan dashboard.
        #expect(launcher.lastSpawnedProcess?.terminatedCount.value == 1)
    }

    @Test
    func acquireFailsWhenProcessExitsBeforeReachable() async throws {
        let launcher = StubLauncher()
        // Have the stub process exit immediately with code 1 on launch.
        launcher.onLaunch = { process in
            process.simulateExit(code: 1)
        }
        let http = StubHTTP(responses: [])
        let supervisor = DashboardSupervisor(
            profile: ServerProfile(name: "L", kind: .local, hermesPath: "/bin/hermes"),
            launcher: launcher,
            http: http,
            portAllocator: { 51919 },
            reachabilityTimeout: 5.0,
            reachabilityPollInterval: 0.02
        )

        await #expect(throws: DashboardSupervisorError.exitedBeforeReady(exitCode: 1, stderr: "")) {
            _ = try await supervisor.acquire()
        }
    }

    @Test
    func acquireSurfacesMissingWebExtraFromStderr() async throws {
        let launcher = StubLauncher()
        launcher.onLaunch = { process in
            process.appendStderr("Traceback (most recent call last):\n")
            process.appendStderr("ModuleNotFoundError: No module named 'fastapi'\n")
            process.simulateExit(code: 1)
        }
        let http = StubHTTP(responses: [])
        let supervisor = DashboardSupervisor(
            profile: ServerProfile(name: "L", kind: .local, hermesPath: "/bin/hermes"),
            launcher: launcher,
            http: http,
            portAllocator: { 51919 },
            reachabilityTimeout: 5.0,
            reachabilityPollInterval: 0.02
        )

        await #expect(throws: DashboardSupervisorError.missingWebExtra) {
            _ = try await supervisor.acquire()
        }
    }

    // MARK: - Helpers

    private func makeSPAHTML(token: String) -> String {
        "<html><head><script>window.__HERMES_SESSION_TOKEN__=\"\(token)\";</script></head></html>"
    }
}

// MARK: - Test doubles

final class StubLauncher: DashboardProcessLauncher, @unchecked Sendable {
    private let queue = DispatchQueue(label: "StubLauncher")
    private var _launchedSpecs: [DashboardSpawnSpec] = []
    private var _lastSpawnedProcess: StubDashboardProcess?
    var onLaunch: (@Sendable (StubDashboardProcess) -> Void)?

    var launchedSpecs: [DashboardSpawnSpec] { queue.sync { _launchedSpecs } }
    var lastSpawnedProcess: StubDashboardProcess? { queue.sync { _lastSpawnedProcess } }

    func launch(spec: DashboardSpawnSpec) async throws -> any DashboardProcess {
        let process = StubDashboardProcess()
        queue.sync {
            _launchedSpecs.append(spec)
            _lastSpawnedProcess = process
        }
        onLaunch?(process)
        return process
    }
}

final class StubDashboardProcess: DashboardProcess, @unchecked Sendable {
    let terminatedCount = Counter()
    private let queue = DispatchQueue(label: "StubDashboardProcess")
    private var _exitCode: Int32?
    private let stderrCont: AsyncStream<String>.Continuation
    let stderrLines: AsyncStream<String>
    private let exitCont: AsyncStream<Int32>.Continuation
    let exitStream: AsyncStream<Int32>

    init() {
        var capturedStderr: AsyncStream<String>.Continuation?
        self.stderrLines = AsyncStream { capturedStderr = $0 }
        self.stderrCont = capturedStderr!
        var capturedExit: AsyncStream<Int32>.Continuation?
        self.exitStream = AsyncStream { capturedExit = $0 }
        self.exitCont = capturedExit!
    }

    var stderr: AsyncStream<String> { stderrLines }

    func appendStderr(_ line: String) {
        stderrCont.yield(line)
    }

    func simulateExit(code: Int32) {
        queue.sync { _exitCode = code }
        stderrCont.finish()
        exitCont.yield(code)
        exitCont.finish()
    }

    func terminate() async {
        terminatedCount.increment()
        queue.sync { _exitCode = 143 }
        stderrCont.finish()
        exitCont.yield(143)
        exitCont.finish()
    }

    func waitForExit() async -> Int32 {
        for await code in exitStream {
            return code
        }
        return 0
    }

    func exitCodeIfAvailable() async -> Int32? {
        queue.sync { _exitCode }
    }
}

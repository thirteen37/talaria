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
    func forceShutdownTerminatesRunningProcessIgnoringRefcount() async throws {
        let launcher = StubLauncher()
        let http = StubHTTP(responses: [
            .init(path: "/api/status", body: Data(#"{"version":"0.14.0"}"#.utf8)),
            .init(path: "/", body: Data(makeSPAHTML(token: "T").utf8)),
        ])
        let supervisor = DashboardSupervisor(
            profile: ServerProfile(name: "L", kind: .local, hermesPath: "/bin/hermes"),
            launcher: launcher,
            http: http,
            portAllocator: { 51919 }
        )

        _ = try await supervisor.acquire()
        _ = try await supervisor.acquire()  // refcount 2 — force must ignore it
        await supervisor.forceShutdown()

        #expect(launcher.lastSpawnedProcess?.terminatedCount.value == 1)
        #expect(await supervisor.isFullyReleased)
    }

    @Test
    func acquireAfterForceShutdownSpawnsFresh() async throws {
        let launcher = StubLauncher()
        let http = StubHTTP(responses: [
            .init(path: "/api/status", body: Data(#"{"version":"0.14.0"}"#.utf8)),
            .init(path: "/", body: Data(makeSPAHTML(token: "T1").utf8)),
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
        await supervisor.forceShutdown()
        let endpoint = try await supervisor.acquire()

        // A genuinely new process + session — the reconnect path.
        #expect(launcher.launchedSpecs.count == 2)
        #expect(endpoint.session.tokenSnapshot() == "T2")
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
    func acquireAfterReleaseToZeroDuringPendingSpawnStartsFresh() async throws {
        // Regression: when the last pending consumer releases during startup we
        // cancel the in-flight spawn. If `pendingAcquire` is left set, an
        // `acquire()` arriving while the cancelled spawn is still unwinding
        // (here: blocked in `launch`) coalesces onto the dead task and inherits
        // its `CancellationError` instead of spawning fresh. The gate pins the
        // first spawn inside `launch` so the second acquire hits that exact
        // window deterministically.
        let gate = Gate()
        let launcher = StubLauncher()
        launcher.launchGate = { await gate.wait() }
        let http = StubHTTP(responses: [])  // never reachable
        let supervisor = DashboardSupervisor(
            profile: ServerProfile(name: "L", kind: .local, hermesPath: "/bin/hermes"),
            launcher: launcher,
            http: http,
            portAllocator: { 51919 },
            reachabilityTimeout: 0.1,
            reachabilityPollInterval: 0.02
        )

        let acquire1 = Task { try await supervisor.acquire() }
        while launcher.launchedSpecs.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        // Last pending consumer releases: cancels the spawn and clears the slot.
        await supervisor.release()

        // New acquirer arrives while the cancelled spawn is still gated in
        // `launch`. With the fix it starts its own spawn rather than coalescing.
        // (Bounded sleep, not a spin on launch count: the buggy path coalesces
        // and never reaches a second launch, so this fails fast on the
        // assertions below rather than hanging.)
        let acquire2 = Task { try await supervisor.acquire() }
        try await Task.sleep(nanoseconds: 50_000_000)

        await gate.open()

        await #expect(throws: CancellationError.self) {
            _ = try await acquire1.value
        }
        // acquire2 must not inherit the cancellation — it fails only because the
        // stub never becomes reachable, proving it ran its own spawn.
        do {
            _ = try await acquire2.value
            Issue.record("Expected notReachable")
        } catch DashboardSupervisorError.notReachable {
            // Expected: ran its own spawn, which never became reachable.
        } catch is CancellationError {
            Issue.record("acquire2 inherited the cancellation instead of spawning fresh")
        }
        #expect(launcher.launchedSpecs.count == 2)
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

        do {
            _ = try await supervisor.acquire()
            Issue.record("Expected notReachable")
        } catch let DashboardSupervisorError.notReachable(lastProbeError) {
            // The probe error must be captured so the banner/log can say *why*
            // it never came online rather than a content-free timeout.
            #expect(lastProbeError != nil)
        }
        // Failed startup must also terminate the process so we don't leak
        // an orphan dashboard.
        #expect(launcher.lastSpawnedProcess?.terminatedCount.value == 1)
    }

    @Test
    func notReachableCapturesLastProbeError() async throws {
        // The real-world symptom (remote `ssh -L` forward up but the dashboard
        // never serving) surfaces as a repeated URLError on the probe. That
        // error must ride along on `notReachable` so the UI and Log Console can
        // name it (`-1005` connection-lost vs refused vs a non-2xx status)
        // instead of the generic "didn't come online".
        let launcher = StubLauncher()
        let http = AlwaysFailingHTTP(error: URLError(.networkConnectionLost))
        let supervisor = DashboardSupervisor(
            profile: ServerProfile(name: "L", kind: .local, hermesPath: "/bin/hermes"),
            launcher: launcher,
            http: http,
            portAllocator: { 51919 },
            reachabilityTimeout: 0.1,
            reachabilityPollInterval: 0.02
        )

        do {
            _ = try await supervisor.acquire()
            Issue.record("Expected notReachable")
        } catch let DashboardSupervisorError.notReachable(lastProbeError) {
            let detail = try #require(lastProbeError)
            // -1005 is the raw URLError code; the description proves the probe
            // failure reason rode along rather than being swallowed.
            #expect(detail.contains("-1005"))
        }
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

    @Test
    func webUIBuildExtendsReachabilityWindowPastBaseTimeout() async throws {
        // The dashboard announces it's compiling the web UI, then only starts
        // serving well after the (tiny) base window. Because the build marker
        // was seen, the supervisor keeps probing up to the build cap and the
        // acquire succeeds instead of failing with notReachable.
        let launcher = StubLauncher()
        launcher.onLaunch = { process in
            process.appendStderr("Building web UI...\n")
        }
        let http = EventuallyReachableHTTP(failStatusProbes: 10, token: "T")
        let supervisor = DashboardSupervisor(
            profile: ServerProfile(name: "L", kind: .local, hermesPath: "/bin/hermes"),
            launcher: launcher,
            http: http,
            portAllocator: { 51919 },
            reachabilityTimeout: 0.1,
            reachabilityPollInterval: 0.02,
            buildReachabilityTimeout: 5.0
        )

        let endpoint = try await supervisor.acquire()
        #expect(endpoint.session.tokenSnapshot() == "T")
        // Status was refused for ~0.2s — comfortably past the 0.1s base window,
        // proving the build marker is what kept the probe loop alive.
        #expect(http.statusProbeCount > 10)
    }

    @Test
    func withoutBuildMarkerTheBaseTimeoutStillApplies() async throws {
        // Same slow-to-serve dashboard, but no build marker: the base window
        // governs and the acquire fails fast rather than waiting the build cap.
        let launcher = StubLauncher()
        let http = EventuallyReachableHTTP(failStatusProbes: 10_000, token: "T")
        let supervisor = DashboardSupervisor(
            profile: ServerProfile(name: "L", kind: .local, hermesPath: "/bin/hermes"),
            launcher: launcher,
            http: http,
            portAllocator: { 51919 },
            reachabilityTimeout: 0.1,
            reachabilityPollInterval: 0.02,
            buildReachabilityTimeout: 30.0
        )

        do {
            _ = try await supervisor.acquire()
            Issue.record("Expected notReachable within the base window")
        } catch DashboardSupervisorError.notReachable {
            // Expected — no build marker, so the 30s build cap never engaged.
        }
    }

    @Test
    func acquireFiresWebUIBuildCallbackWhileBuilding() async throws {
        // The build callback is the seam the UI's "Building web UI…" banner
        // hangs on — it must fire while the dashboard is still building, before
        // acquire() returns the live endpoint.
        let launcher = StubLauncher()
        launcher.onLaunch = { process in
            process.appendStderr("Building web UI...\n")
        }
        let http = EventuallyReachableHTTP(failStatusProbes: 5, token: "T")
        let supervisor = DashboardSupervisor(
            profile: ServerProfile(name: "L", kind: .local, hermesPath: "/bin/hermes"),
            launcher: launcher,
            http: http,
            portAllocator: { 51919 },
            reachabilityTimeout: 0.2,
            reachabilityPollInterval: 0.02,
            buildReachabilityTimeout: 5.0
        )

        let fired = Counter()
        _ = try await supervisor.acquire(onWebUIBuildDetected: { fired.increment() })
        #expect(fired.value >= 1)
    }

    @Test
    func buildMarkerSplitAcrossChunksStillLatches() async {
        // An SSH/pipe read can split the marker mid-line; the buffer must match
        // across chunk boundaries, not per-chunk, or the slow remote build falls
        // back to the base timeout and fails.
        let buffer = DashboardStderrBuffer()
        await buffer.append("Building web ")
        #expect(await buffer.sawWebUIBuild == false)
        await buffer.append("UI…\n")
        #expect(await buffer.sawWebUIBuild == true)
    }

    @Test
    func indicatesWebUIBuildMatchesHermesBuildMessage() {
        #expect(DashboardSupervisor.indicatesWebUIBuild("Building web UI...\n"))
        #expect(DashboardSupervisor.indicatesWebUIBuild("  building WEB ui bundle"))
        #expect(!DashboardSupervisor.indicatesWebUIBuild("Uvicorn running on http://127.0.0.1:8787"))
        #expect(!DashboardSupervisor.indicatesWebUIBuild(
            "channel 3: open failed: connect failed: Connection refused"
        ))
    }

    // MARK: - Helpers

    private func makeSPAHTML(token: String) -> String {
        "<html><head><script>window.__HERMES_SESSION_TOKEN__=\"\(token)\";</script></head></html>"
    }
}

// MARK: - Test doubles

/// Always throws the same error from `data(for:)` — models a dashboard whose
/// `/api/status` never answers (e.g. an `ssh -L` forward whose remote port is
/// dead), so every reachability probe fails identically.
final class AlwaysFailingHTTP: DashboardHTTP, @unchecked Sendable {
    private let error: any Error
    init(error: any Error) { self.error = error }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw error }
}

/// Refuses `/api/status` for the first `failStatusProbes` probes, then serves a
/// 200, modelling a dashboard that's slow to start listening (e.g. compiling its
/// web UI). `GET /` always returns the SPA so the post-reachable token scrape
/// succeeds.
final class EventuallyReachableHTTP: DashboardHTTP, @unchecked Sendable {
    private let queue = DispatchQueue(label: "EventuallyReachableHTTP")
    private let failStatusProbes: Int
    private let token: String
    private var _statusProbeCount = 0

    init(failStatusProbes: Int, token: String) {
        self.failStatusProbes = failStatusProbes
        self.token = token
    }

    var statusProbeCount: Int { queue.sync { _statusProbeCount } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        if path == "/api/status" {
            let n = queue.sync { _statusProbeCount += 1; return _statusProbeCount }
            if n <= failStatusProbes { throw URLError(.cannotConnectToHost) }
            return (Data(#"{"version":"0.14.0"}"#.utf8), Self.ok(request.url!))
        }
        let html = "<html><head><script>window.__HERMES_SESSION_TOKEN__=\"\(token)\";</script></head></html>"
        return (Data(html.utf8), Self.ok(request.url!))
    }

    private static func ok(_ url: URL) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}

final class StubLauncher: DashboardProcessLauncher, @unchecked Sendable {
    private let queue = DispatchQueue(label: "StubLauncher")
    private var _launchedSpecs: [DashboardSpawnSpec] = []
    private var _lastSpawnedProcess: StubDashboardProcess?
    var onLaunch: (@Sendable (StubDashboardProcess) -> Void)?
    /// Optional async barrier awaited before `launch` returns, letting a test
    /// pin a spawn mid-flight to exercise startup races deterministically.
    var launchGate: (@Sendable () async -> Void)?

    var launchedSpecs: [DashboardSpawnSpec] { queue.sync { _launchedSpecs } }
    var lastSpawnedProcess: StubDashboardProcess? { queue.sync { _lastSpawnedProcess } }

    func launch(spec: DashboardSpawnSpec) async throws -> any DashboardProcess {
        let process = StubDashboardProcess()
        queue.sync {
            _launchedSpecs.append(spec)
            _lastSpawnedProcess = process
        }
        onLaunch?(process)
        await launchGate?()
        return process
    }
}

/// One-shot gate: `wait()` suspends until `open()` is called, after which all
/// current and future waiters proceed immediately.
actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
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

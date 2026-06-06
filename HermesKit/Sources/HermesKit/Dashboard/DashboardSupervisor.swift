import Foundation

public enum DashboardSupervisorError: Error, Equatable, Sendable, LocalizedError {
    /// Process spawned but never began serving — `/api/status` didn't respond
    /// with 2xx within the timeout. Most often a Hermes the dashboard
    /// can't start (bad config, port in use, missing dependencies).
    ///
    /// `lastProbeError` is the reason the final reachability probe failed
    /// (e.g. `The network connection was lost. (URLError -1005)` for a remote
    /// `ssh -L` forward whose remote port is dead, or a non-2xx status). It's
    /// nil only if the deadline elapsed before any probe ran. Carrying it makes
    /// the difference between "couldn't reach the forward" and "reached it, got
    /// a 500" visible in the banner instead of a content-free timeout.
    case notReachable(lastProbeError: String?)
    /// Process exited before `/api/status` became reachable. `stderr` carries
    /// whatever tail we managed to capture; UI surfaces it verbatim because
    /// the actionable fix is almost always reading the message.
    case exitedBeforeReady(exitCode: Int32, stderr: String)
    /// `pip install hermes-agent[web]` was never run on the spawn host;
    /// stderr contained a `ModuleNotFoundError` for one of the FastAPI/
    /// Uvicorn dependencies. Surface a structured error so callers (and
    /// Doctor) can offer the install command rather than dumping a Python
    /// traceback at the user.
    case missingWebExtra

    public var errorDescription: String? {
        switch self {
        case let .notReachable(lastProbeError):
            let base = "Dashboard didn't come online before the reachability timeout."
            guard let lastProbeError, !lastProbeError.isEmpty else { return base }
            return "\(base) Last probe: \(lastProbeError)"
        case let .exitedBeforeReady(code, stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "Dashboard process exited with code \(code) before becoming ready."
                : "Dashboard process exited (code \(code)) before ready: \(trimmed)"
        case .missingWebExtra:
            return "Dashboard requires `pip install hermes-agent[web]`."
        }
    }
}

/// Why a spawning dashboard isn't reachable yet, reported to the acquiring UI
/// so it can show honest progress copy during the (possibly long) startup wait
/// instead of a hintless "connecting…".
public enum DashboardStartupPhase: Sendable, Equatable {
    /// The captured output showed Hermes' `Building web UI…` marker — it's
    /// confirmed compiling its web bundle (first `hermes dashboard` after an
    /// update). The UI may assert the build in copy.
    case buildingWebUI
    /// The process is alive but the endpoint hasn't started listening within the
    /// base window, and **no** build marker was seen — the common remote,
    /// non-PTY case where the marker never streams. It's *likely* still
    /// starting/compiling, but the cause is unconfirmed (could equally be a
    /// misconfig or a wedged process), so the UI must not assert a build.
    case slowToStart
}

/// One running `hermes dashboard` for one `ServerProfile`.
///
/// Acquires/releases reference-count consumers (Sessions browser, Updates
/// view, Doctor probe) so the process starts on first use and stops on last.
/// The launcher abstraction lets tests inject a stub; production uses
/// `SystemDashboardProcessLauncher` which shells out to `/usr/bin/ssh` or
/// the local `hermes` binary.
public actor DashboardSupervisor {
    // `nonisolated` so the coordinator can compare/evict by profile without
    // hopping onto the actor — it's an immutable `Sendable` value.
    public nonisolated let profile: ServerProfile

    /// Hermes profile (`hermes -p <name>`) this dashboard is scoped to. nil or
    /// `default` spawns the unscoped dashboard (the shared window dashboard);
    /// a named profile scopes every config op to that profile's `HERMES_HOME`.
    public nonisolated let hermesProfileName: String?

    private let launcher: any DashboardProcessLauncher
    private let http: any DashboardHTTP
    private let portAllocator: @Sendable () throws -> Int
    private let reachabilityTimeout: TimeInterval
    private let reachabilityPollInterval: TimeInterval
    /// Extended deadline used once the captured output shows Hermes is building
    /// its web UI (first `hermes dashboard` after an update). Compiling the web
    /// bundle — especially on a remote host reached over `ssh -L` — routinely
    /// outlasts `reachabilityTimeout`, so we wait up to this cap rather than
    /// declaring the dashboard dead mid-build.
    private let buildReachabilityTimeout: TimeInterval

    private var refcount: Int = 0
    private var pendingRefcount: Int = 0
    private var current: ActiveProcess?
    private var currentGeneration: Int?
    private var discardedPendingGeneration: Int?
    /// In-flight spawn shared by concurrent acquirers. Without this, two
    /// callers arriving while `current` is nil would each see nil after the
    /// first `await spawnAndReady()` suspends the actor, and each would
    /// launch its own `hermes dashboard` — one of which then leaks (no
    /// terminate) because `current` only holds the last assignment.
    private var pendingAcquire: PendingAcquire?
    private var pendingGeneration: Int = 0

    private struct ActiveProcess {
        let process: any DashboardProcess
        let endpoint: DashboardEndpoint
        let stderrBuffer: DashboardStderrBuffer
    }

    private struct PendingAcquire {
        let generation: Int
        let task: Task<ActiveProcess, Error>
    }

    public init(
        profile: ServerProfile,
        hermesProfileName: String? = nil,
        launcher: any DashboardProcessLauncher,
        http: any DashboardHTTP,
        portAllocator: @escaping @Sendable () throws -> Int,
        reachabilityTimeout: TimeInterval = 20,
        reachabilityPollInterval: TimeInterval = 0.2,
        buildReachabilityTimeout: TimeInterval = 180
    ) {
        self.profile = profile
        self.hermesProfileName = hermesProfileName
        self.launcher = launcher
        self.http = http
        self.portAllocator = portAllocator
        self.reachabilityTimeout = reachabilityTimeout
        self.reachabilityPollInterval = reachabilityPollInterval
        self.buildReachabilityTimeout = max(buildReachabilityTimeout, reachabilityTimeout)
    }

    /// - Parameter onStartupProgress: fired once (on this actor) the first time
    ///   the spawning dashboard is observed still coming up — either confirmed
    ///   building its web UI (``DashboardStartupPhase/buildingWebUI``) or merely
    ///   alive-but-not-listening past the base window with no marker
    ///   (``DashboardStartupPhase/slowToStart``) — so a consumer can surface a
    ///   progress banner with copy honest to the phase. Only the acquirer that
    ///   triggers the spawn wires its callback; coalesced acquirers don't,
    ///   matching how the spawn itself is shared. Ignored when the dashboard is
    ///   already running.
    public func acquire(
        onStartupProgress: (@Sendable (DashboardStartupPhase) async -> Void)? = nil
    ) async throws -> DashboardEndpoint {
        if let current {
            refcount += 1
            return current.endpoint
        }
        if let pending = pendingAcquire {
            // Coalesce: another acquirer is already spawning. Reserve this
            // consumer before awaiting so a matching release during startup
            // can cancel or tear down the pending process.
            pendingRefcount += 1
            return try await finishPendingAcquire(pending)
        }
        let task = Task<ActiveProcess, Error> { [self] in
            try await self.spawnAndReady(onStartupProgress: onStartupProgress)
        }
        pendingGeneration += 1
        let pending = PendingAcquire(generation: pendingGeneration, task: task)
        pendingAcquire = pending
        pendingRefcount = 1
        return try await finishPendingAcquire(pending)
    }

    private func finishPendingAcquire(_ pending: PendingAcquire) async throws -> DashboardEndpoint {
        do {
            let active = try await pending.task.value
            if currentGeneration == pending.generation, let current {
                return current.endpoint
            }
            if discardedPendingGeneration == pending.generation {
                throw CancellationError()
            }
            guard pendingAcquire?.generation == pending.generation else {
                await active.process.terminate()
                discardedPendingGeneration = pending.generation
                throw CancellationError()
            }
            if current == nil {
                pendingAcquire = nil
                if pendingRefcount > 0 {
                    installAcquired(active, refcount: pendingRefcount, generation: pending.generation)
                    pendingRefcount = 0
                } else {
                    pendingRefcount = 0
                    await active.process.terminate()
                    discardedPendingGeneration = pending.generation
                    throw CancellationError()
                }
            }
            guard let current else {
                throw CancellationError()
            }
            return current.endpoint
        } catch {
            if pendingAcquire?.generation == pending.generation {
                pendingAcquire = nil
                pendingRefcount = 0
            }
            throw error
        }
    }

    private func installAcquired(_ active: ActiveProcess, refcount: Int, generation: Int) {
        current = active
        currentGeneration = generation
        self.refcount = refcount
    }

    /// True when no consumer holds the supervisor and nothing is spawning —
    /// the process (if any) has been terminated. The coordinator uses this to
    /// evict a fully-released supervisor from its per-profile cache so a later
    /// acquire rebuilds against the current profile config.
    public var isFullyReleased: Bool {
        refcount == 0 && pendingRefcount == 0 && current == nil && pendingAcquire == nil
    }

    public func release() async {
        if current == nil, pendingAcquire != nil {
            guard pendingRefcount > 0 else { return }
            pendingRefcount -= 1
            if pendingRefcount == 0 {
                pendingAcquire?.task.cancel()
                // Clear the pending slot now rather than waiting for the
                // cancelled task to unwind through `finishPendingAcquire`'s
                // catch block. Otherwise an `acquire()` arriving while the
                // cancelled spawn is still unwinding (e.g. blocked in
                // `launcher.launch`/SSH connect before its next cancellation
                // check) would coalesce onto the dead task and get a spurious
                // `CancellationError` instead of a freshly spawned dashboard.
                // The stale task's `finishPendingAcquire` no-ops on its
                // generation mismatch and terminates any process it spawned.
                pendingAcquire = nil
            }
            return
        }
        guard refcount > 0 else { return }
        refcount -= 1
        if refcount == 0, let active = current {
            await active.process.terminate()
            current = nil
            currentGeneration = nil
        }
    }

    /// Unconditionally tears down the running dashboard, ignoring the refcount —
    /// the reconnect path for a wedged process (dropped `ssh -L` forward, crashed
    /// or restarted remote) that a normal refcounted ``release()`` wouldn't kill.
    /// Afterwards the supervisor is fully released, so the coordinator evicts it
    /// and the next ``acquire()`` builds a fresh process; callers reconnect by
    /// re-acquiring.
    public func forceShutdown() async {
        // Abandon any in-flight spawn so a concurrent acquirer can't install a
        // process we're tearing down. The cancelled task's `finishPendingAcquire`
        // terminates whatever it spawned once it unwinds.
        if let pending = pendingAcquire {
            pending.task.cancel()
            pendingAcquire = nil
        }
        pendingRefcount = 0
        refcount = 0
        guard let active = current else { return }
        // Clear `current` before the suspending `terminate()` so a concurrent
        // acquirer sees "nothing running" and spawns fresh rather than being
        // handed the dying endpoint.
        current = nil
        currentGeneration = nil
        await active.process.terminate()
    }

    // MARK: - Spawn

    private func spawnAndReady(
        onStartupProgress: (@Sendable (DashboardStartupPhase) async -> Void)? = nil
    ) async throws -> ActiveProcess {
        let port = try portAllocator()
        let spec = buildSpec(port: port)
        // The exact command — invaluable for diagnosing remote spawns (right
        // port forwarded? watchdog wrapper intact?). Arguments carry host/user/
        // identity-file *path* but never key material, so this is log-safe.
        HermesLog.dashboard.debug(
            "Spawning dashboard for \(self.profile.name, privacy: .public) on port \(port, privacy: .public): \(spec.executable.path, privacy: .public) \(spec.arguments.joined(separator: " "), privacy: .public)"
        )
        let process = try await launcher.launch(spec: spec)
        let stderrBuffer = DashboardStderrBuffer()
        let stderrTap = Task.detached { [stderrBuffer] in
            for await line in process.stderr {
                await stderrBuffer.append(line)
                // Mirror to the log so the dashboard's own output — including
                // uvicorn's WebSocket access/rejection lines for `/api/ws` — is
                // visible in the in-app console, not just on early-exit failures.
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    HermesLog.dashboard.info("[dashboard] \(trimmed, privacy: .public)")
                }
            }
        }

        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let session = DashboardSession(baseURL: baseURL, http: http)

        do {
            try await waitForReachable(
                process: process,
                stderr: stderrBuffer,
                stderrTap: stderrTap,
                baseURL: baseURL,
                onStartupProgress: onStartupProgress
            )
            // Warm the session token so the first authenticated call from a
            // consumer doesn't pay an extra round-trip.
            _ = try await session.refresh()
        } catch {
            stderrTap.cancel()
            await process.terminate()
            throw error
        }

        let endpoint = DashboardEndpoint(baseURL: baseURL, session: session)
        return ActiveProcess(process: process, endpoint: endpoint, stderrBuffer: stderrBuffer)
    }

    private func buildSpec(port: Int) -> DashboardSpawnSpec {
        switch profile.kind {
        case .local:
            return DashboardSpawnSpec.local(profile: profile, port: port, hermesProfileName: hermesProfileName)
        case .ssh:
            #if os(macOS)
            // macOS forwards through `/usr/bin/ssh -L` so the local port maps
            // 1:1 to the remote port.
            return DashboardSpawnSpec.remote(
                profile: profile,
                localPort: port,
                remotePort: port,
                hermesProfileName: hermesProfileName
            )
            #else
            // iOS reaches the remote dashboard over NIO-SSH `direct-tcpip`,
            // so there's no local forward — `port` is purely the remote port.
            return DashboardSpawnSpec.remoteNIO(profile: profile, port: port, hermesProfileName: hermesProfileName)
            #endif
        }
    }

    private func waitForReachable(
        process: any DashboardProcess,
        stderr: DashboardStderrBuffer,
        stderrTap: Task<Void, Never>,
        baseURL: URL,
        onStartupProgress: (@Sendable (DashboardStartupPhase) async -> Void)? = nil
    ) async throws {
        let start = Date()
        let baseDeadline = start.addingTimeInterval(reachabilityTimeout)
        let buildDeadline = start.addingTimeInterval(buildReachabilityTimeout)
        var lastProbeError: String?
        // Whether the endpoint has ever answered at the HTTP level. The wait is
        // gated on *observed behavior*, not the fragile `Building web UI…` text
        // marker (which a remote, non-PTY `hermes dashboard` never streams in
        // time): while the process is alive and the port isn't listening yet
        // (probe fails at the transport level — refused/lost), treat it as "still
        // coming up" and wait up to the build cap. Once it's listening but
        // unhealthy (a non-2xx HTTP response), the build is done and waiting
        // longer won't help, so fall back to the short base window.
        var sawListening = false
        // The build-feedback callback fires at most once, on whichever comes
        // first: the textual `Building web UI…` marker, or simply crossing the
        // base window while still not listening (the remote non-PTY case, where
        // the marker never appears). Either way the user gets "still starting…"
        // context for the long wait.
        var firedBuildFeedback = false
        while true {
            try Task.checkCancellation()
            if let code = await process.exitCodeIfAvailable() {
                try await Self.throwEarlyExit(code: code, stderr: stderr, stderrTap: stderrTap)
            }
            switch await Self.probeReachability(baseURL: baseURL, http: http) {
            case .reachable:
                return
            case let .notListening(reason):
                lastProbeError = reason
                HermesLog.dashboard.debug(
                    "Dashboard probe \(baseURL.absoluteString, privacy: .public)/api/status not listening: \(reason, privacy: .public)"
                )
            case let .listeningButUnhealthy(reason):
                sawListening = true
                lastProbeError = reason
                HermesLog.dashboard.debug(
                    "Dashboard probe \(baseURL.absoluteString, privacy: .public)/api/status listening but unhealthy: \(reason, privacy: .public)"
                )
            }

            let now = Date()
            // The `Building web UI…` marker is now UX-only — it no longer gates
            // the wait, but when it does appear it confirms the build, so the UI
            // can assert it in the banner copy.
            if !firedBuildFeedback, await stderr.sawWebUIBuild {
                firedBuildFeedback = true
                HermesLog.dashboard.info(
                    "Dashboard \(self.profile.name, privacy: .public) is building its web UI; waiting up to \(self.buildReachabilityTimeout, privacy: .public)s for it to start listening."
                )
                await onStartupProgress?(.buildingWebUI)
            }
            // Even without the marker, once we've waited past the base window and
            // the endpoint still isn't listening, surface progress so the spinner
            // has context during the (possibly long) wait. The cause is
            // unconfirmed here — it's *likely* still building, but could be a
            // wedged/misconfigured process — so report `.slowToStart`, not a
            // definite build, and let the UI hedge its copy accordingly.
            if !firedBuildFeedback, !sawListening, now >= baseDeadline {
                firedBuildFeedback = true
                HermesLog.dashboard.info(
                    "Dashboard \(self.profile.name, privacy: .public) still not listening after \(self.reachabilityTimeout, privacy: .public)s; waiting up to \(self.buildReachabilityTimeout, privacy: .public)s in case it's still starting/building."
                )
                await onStartupProgress?(.slowToStart)
            }

            if now >= (sawListening ? baseDeadline : buildDeadline) {
                break
            }
            try? await Task.sleep(nanoseconds: UInt64(reachabilityPollInterval * 1_000_000_000))
        }

        if let code = await process.exitCodeIfAvailable() {
            try await Self.throwEarlyExit(code: code, stderr: stderr, stderrTap: stderrTap)
        }
        // Still running but never served. Snapshot whatever the process has
        // written so far — we can't await `stderrTap` here, it only ends when
        // the process exits, which by definition hasn't happened on this path.
        let sawBuildMarker = await stderr.sawWebUIBuild
        let capturedStderr = await stderr.snapshot()
        HermesLog.dashboard.error(
            """
            Dashboard \(self.profile.name, privacy: .public) (\(String(describing: self.profile.kind), privacy: .public)) \
            didn't come online at \(baseURL.absoluteString, privacy: .public) after \
            \(sawListening ? self.reachabilityTimeout : self.buildReachabilityTimeout, privacy: .public)s \
            (listening: \(sawListening, privacy: .public), web-UI build marker: \(sawBuildMarker, privacy: .public)). \
            Last probe: \(lastProbeError ?? "none", privacy: .public). \
            Process output so far: \(capturedStderr.isEmpty ? "<empty>" : capturedStderr, privacy: .public)
            """
        )
        throw DashboardSupervisorError.notReachable(lastProbeError: lastProbeError)
    }

    private static func throwEarlyExit(
        code: Int32,
        stderr: DashboardStderrBuffer,
        stderrTap: Task<Void, Never>
    ) async throws {
        // Drain the stderr stream to completion before snapshotting. The exit
        // code can publish before the stderr tap has appended every buffered
        // line; the tap loop ends when the stream closes, so awaiting it
        // guarantees the snapshot sees the actionable bottom-most error.
        await stderrTap.value
        let captured = await stderr.snapshot()
        if stderrIndicatesMissingWebExtra(captured) {
            throw DashboardSupervisorError.missingWebExtra
        }
        throw DashboardSupervisorError.exitedBeforeReady(exitCode: code, stderr: captured)
    }

    private enum ReachabilityOutcome {
        /// `/api/status` answered with a 2xx — the dashboard is serving.
        case reachable
        /// The probe never reached an HTTP server: a transport-level failure
        /// (connection refused/lost, forward dead, port not yet bound). The
        /// dashboard is either still coming up (compiling its web UI) or truly
        /// down — the supervisor keeps waiting up to the build cap to tell them
        /// apart, since an early process exit fails fast separately.
        case notListening(reason: String)
        /// The endpoint answered with an `HTTPURLResponse` but a non-2xx status:
        /// the port is bound and the server is up, just unhealthy. Waiting the
        /// long build cap won't help, so the supervisor falls back to the short
        /// base window.
        case listeningButUnhealthy(reason: String)
    }

    private static func probeReachability(
        baseURL: URL,
        http: any DashboardHTTP
    ) async -> ReachabilityOutcome {
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/status"))
        request.httpMethod = "GET"
        do {
            let (_, response) = try await http.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                // Non-HTTP response is unexpected, but the transport answered —
                // treat as reachable rather than spinning out the whole window.
                return .reachable
            }
            if (200..<300).contains(http.statusCode) {
                return .reachable
            }
            return .listeningButUnhealthy(reason: "HTTP \(http.statusCode)")
        } catch {
            return .notListening(reason: Self.describeProbeError(error))
        }
    }

    /// Log-safe one-liner for a probe failure. For `URLError` (the common case
    /// over loopback or an `ssh -L` forward) it appends the raw code — `-1005`
    /// (connection lost), `-1004` (can't connect / refused) — the single most
    /// diagnostic bit for telling "forward up but dashboard dead" apart from
    /// "still booting". No credential material flows through here.
    private static func describeProbeError(_ error: any Error) -> String {
        if let urlError = error as? URLError {
            return "\(urlError.localizedDescription) (URLError \(urlError.code.rawValue))"
        }
        return error.localizedDescription
    }

    private static func stderrIndicatesMissingWebExtra(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("modulenotfounderror") &&
            (lower.contains("fastapi") || lower.contains("uvicorn") || lower.contains("starlette"))
    }

    /// True when a captured output line looks like Hermes compiling its web UI
    /// (`Building web UI…`), emitted on the first `hermes dashboard` after an
    /// update. It's the signal that a not-yet-listening dashboard is simply
    /// still building, so the supervisor extends the reachability window instead
    /// of declaring it dead.
    static func indicatesWebUIBuild(_ line: String) -> Bool {
        line.lowercased().contains("building web ui")
    }
}

// MARK: - Launcher / Process abstractions

public protocol DashboardProcessLauncher: Sendable {
    /// Spawn the dashboard. Returns once the child has been created — the
    /// caller (supervisor) then polls reachability and watches for early exit.
    func launch(spec: DashboardSpawnSpec) async throws -> any DashboardProcess
}

public protocol DashboardProcess: Sendable {
    /// Stderr lines as they arrive. Closed when the process exits.
    var stderr: AsyncStream<String> { get }
    /// Send SIGTERM (or platform equivalent) and wait for exit. Idempotent.
    func terminate() async
    /// Resolves with the process exit code once the child has reaped.
    func waitForExit() async -> Int32
    /// Returns the exit code if the process has already exited.
    func exitCodeIfAvailable() async -> Int32?
}

public extension DashboardProcess {
    func exitCodeIfAvailable() async -> Int32? { nil }
}

public struct DashboardEndpoint: Sendable {
    public let baseURL: URL
    public let session: DashboardSession
}

/// Accumulates stderr lines so a supervisor can present "what did it say
/// before exiting?" in the error message. Bounded to the most recent 64
/// lines — full Python tracebacks are noise in the UI; the import-error
/// detection only needs the bottom-most exception line.
actor DashboardStderrBuffer {
    private var lines: [String] = []
    private let maxLines: Int = 64

    /// Latches once the captured output shows the web-UI build is underway. The
    /// supervisor polls this to decide whether to keep waiting past the base
    /// reachability window. Sticky because the build marker scrolls out of the
    /// bounded line buffer long before the (slow) build finishes.
    private(set) var sawWebUIBuild = false

    /// Bounded rolling tail of recent output, matched for the build marker. An
    /// SSH/pipe read can split `Building web UI…` across two chunks; matching
    /// each chunk in isolation would miss that, so we match the concatenated
    /// tail instead. Capped so a long-running, non-building dashboard doesn't
    /// grow it unbounded; cleared once the build latches.
    private var buildMatchTail = ""
    private let buildMatchTailLimit = 256

    func append(_ line: String) {
        if !sawWebUIBuild {
            buildMatchTail = String((buildMatchTail + line).suffix(buildMatchTailLimit))
            if DashboardSupervisor.indicatesWebUIBuild(buildMatchTail) {
                sawWebUIBuild = true
                buildMatchTail = ""
            }
        }
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    func snapshot() -> String {
        lines.joined()
    }
}

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

    /// - Parameter onWebUIBuildDetected: fired once (on this actor) the first
    ///   time the spawning dashboard's output shows it's compiling its web UI,
    ///   so a consumer can surface a "Building web UI…" banner during the
    ///   (possibly long) wait. Only the acquirer that triggers the spawn wires
    ///   its callback; coalesced acquirers don't, matching how the spawn itself
    ///   is shared. Ignored when the dashboard is already running.
    public func acquire(
        onWebUIBuildDetected: (@Sendable () async -> Void)? = nil
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
            try await self.spawnAndReady(onWebUIBuildDetected: onWebUIBuildDetected)
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
        onWebUIBuildDetected: (@Sendable () async -> Void)? = nil
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
                onWebUIBuildDetected: onWebUIBuildDetected
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
        onWebUIBuildDetected: (@Sendable () async -> Void)? = nil
    ) async throws {
        let start = Date()
        let baseDeadline = start.addingTimeInterval(reachabilityTimeout)
        let buildDeadline = start.addingTimeInterval(buildReachabilityTimeout)
        var lastProbeError: String?
        var loggedBuildWait = false
        while true {
            try Task.checkCancellation()
            if let code = await process.exitCodeIfAvailable() {
                try await Self.throwEarlyExit(code: code, stderr: stderr, stderrTap: stderrTap)
            }
            switch await Self.probeReachability(baseURL: baseURL, http: http) {
            case .reachable:
                return
            case let .failed(reason):
                lastProbeError = reason
                HermesLog.dashboard.debug(
                    "Dashboard probe \(baseURL.absoluteString, privacy: .public)/api/status not ready: \(reason, privacy: .public)"
                )
            }
            // While the server is compiling its web UI (first launch after an
            // update), wait past the base window up to the build cap rather than
            // giving up on a dashboard that's simply still building.
            let building = await stderr.sawWebUIBuild
            if building, !loggedBuildWait {
                loggedBuildWait = true
                HermesLog.dashboard.info(
                    "Dashboard \(self.profile.name, privacy: .public) is building its web UI; extending the reachability window to \(self.buildReachabilityTimeout, privacy: .public)s."
                )
                await onWebUIBuildDetected?()
            }
            if Date() >= (building ? buildDeadline : baseDeadline) {
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
        let building = await stderr.sawWebUIBuild
        let capturedStderr = await stderr.snapshot()
        HermesLog.dashboard.error(
            """
            Dashboard \(self.profile.name, privacy: .public) (\(String(describing: self.profile.kind), privacy: .public)) \
            didn't come online at \(baseURL.absoluteString, privacy: .public) after \
            \(building ? self.buildReachabilityTimeout : self.reachabilityTimeout, privacy: .public)s \
            (web-UI build detected: \(building, privacy: .public)). \
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
        case reachable
        case failed(reason: String)
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
            return .failed(reason: "HTTP \(http.statusCode)")
        } catch {
            return .failed(reason: Self.describeProbeError(error))
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

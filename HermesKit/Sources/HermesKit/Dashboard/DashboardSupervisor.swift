import Foundation

public enum DashboardSupervisorError: Error, Equatable, Sendable, LocalizedError {
    /// Process spawned but never began serving — `/api/status` didn't respond
    /// with 2xx within the timeout. Most often a Hermes the dashboard
    /// can't start (bad config, port in use, missing dependencies).
    case notReachable
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
        case .notReachable:
            return "Dashboard didn't come online before the reachability timeout."
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
    public let profile: ServerProfile

    private let launcher: any DashboardProcessLauncher
    private let http: any DashboardHTTP
    private let portAllocator: @Sendable () throws -> Int
    private let reachabilityTimeout: TimeInterval
    private let reachabilityPollInterval: TimeInterval

    private var refcount: Int = 0
    private var current: ActiveProcess?
    /// In-flight spawn shared by concurrent acquirers. Without this, two
    /// callers arriving while `current` is nil would each see nil after the
    /// first `await spawnAndReady()` suspends the actor, and each would
    /// launch its own `hermes dashboard` — one of which then leaks (no
    /// terminate) because `current` only holds the last assignment.
    private var pendingAcquire: Task<DashboardEndpoint, Error>?

    private struct ActiveProcess {
        let process: any DashboardProcess
        let endpoint: DashboardEndpoint
        let stderrBuffer: DashboardStderrBuffer
    }

    public init(
        profile: ServerProfile,
        launcher: any DashboardProcessLauncher,
        http: any DashboardHTTP,
        portAllocator: @escaping @Sendable () throws -> Int,
        reachabilityTimeout: TimeInterval = 10,
        reachabilityPollInterval: TimeInterval = 0.2
    ) {
        self.profile = profile
        self.launcher = launcher
        self.http = http
        self.portAllocator = portAllocator
        self.reachabilityTimeout = reachabilityTimeout
        self.reachabilityPollInterval = reachabilityPollInterval
    }

    public func acquire() async throws -> DashboardEndpoint {
        if let current {
            refcount += 1
            return current.endpoint
        }
        if let pending = pendingAcquire {
            // Coalesce: another acquirer is already spawning. Wait for it,
            // then take a reference. The spawn task only sets `refcount = 1`
            // (the first acquirer); every other waiter bumps it on resume.
            let endpoint = try await pending.value
            refcount += 1
            return endpoint
        }
        let task = Task<DashboardEndpoint, Error> { [self] in
            let active = try await self.spawnAndReady()
            await self.installAcquired(active)
            return active.endpoint
        }
        pendingAcquire = task
        do {
            let endpoint = try await task.value
            pendingAcquire = nil
            return endpoint
        } catch {
            // Failed spawn: clear so the next acquire tries again instead of
            // re-throwing the same cached error forever.
            pendingAcquire = nil
            throw error
        }
    }

    private func installAcquired(_ active: ActiveProcess) {
        current = active
        refcount = 1
    }

    public func release() async {
        guard refcount > 0 else { return }
        refcount -= 1
        if refcount == 0, let active = current {
            await active.process.terminate()
            current = nil
        }
    }

    // MARK: - Spawn

    private func spawnAndReady() async throws -> ActiveProcess {
        let port = try portAllocator()
        let spec = buildSpec(port: port)
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
                baseURL: baseURL
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
            return DashboardSpawnSpec.local(profile: profile, port: port)
        case .ssh:
            return DashboardSpawnSpec.remote(profile: profile, localPort: port, remotePort: port)
        }
    }

    private func waitForReachable(
        process: any DashboardProcess,
        stderr: DashboardStderrBuffer,
        stderrTap: Task<Void, Never>,
        baseURL: URL
    ) async throws {
        let deadline = Date().addingTimeInterval(reachabilityTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let code = await process.exitCodeIfAvailable() {
                try await Self.throwEarlyExit(code: code, stderr: stderr, stderrTap: stderrTap)
            }
            if try await Self.probeReachability(baseURL: baseURL, http: http) {
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(reachabilityPollInterval * 1_000_000_000))
        }

        if let code = await process.exitCodeIfAvailable() {
            try await Self.throwEarlyExit(code: code, stderr: stderr, stderrTap: stderrTap)
        }
        throw DashboardSupervisorError.notReachable
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

    private static func probeReachability(
        baseURL: URL,
        http: any DashboardHTTP
    ) async throws -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/status"))
        request.httpMethod = "GET"
        do {
            let (_, response) = try await http.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return true
            }
        } catch {
            // Connection refused while the server is still starting up.
        }
        return false
    }

    private static func stderrIndicatesMissingWebExtra(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("modulenotfounderror") &&
            (lower.contains("fastapi") || lower.contains("uvicorn") || lower.contains("starlette"))
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

    func append(_ line: String) {
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    func snapshot() -> String {
        lines.joined()
    }
}

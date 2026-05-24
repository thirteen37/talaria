#if os(macOS)
import Foundation

public enum SnapshotState: Sendable, Equatable {
    /// Snapshot exists and is at most `ageSeconds` old.
    case fresh(ageSeconds: Int)
    /// Snapshot exists but is older than the freshness threshold.
    case stale(ageSeconds: Int)
    /// No cached snapshot yet.
    case missing
    /// A refresh is in progress.
    case refreshing
    /// The most recent refresh failed.
    case error(String)
}

public enum RemoteSnapshotError: Error, Equatable, Sendable, LocalizedError {
    case notRemoteProfile
    case missingHost
    case sshFailed(SSHTransportError)
    case sqlite3Failed(String)
    case sftpFailed(String)
    case ioFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notRemoteProfile: return "Profile isn't a remote SSH server."
        case .missingHost: return "Profile is missing a host."
        case let .sshFailed(transport): return "SSH: \(transport.message)"
        case let .sqlite3Failed(message): return "sqlite3 .backup failed: \(message)"
        case let .sftpFailed(message): return "sftp failed: \(message)"
        case let .ioFailed(message): return message
        }
    }
}

public actor RemoteSnapshot {
    /// Boundary between `.fresh` and `.stale` for the published state stream.
    /// The UI may further bucket the reported `ageSeconds` (e.g. green for
    /// the first 60s) but that's purely a display decision and lives in the
    /// badge view, not here.
    public static let staleThreshold: TimeInterval = 5 * 60

    public nonisolated let profile: ServerProfile

    private let cacheRoot: URL
    private var subscribers: [UUID: AsyncStream<SnapshotState>.Continuation] = [:]
    private var refreshTask: Task<Void, Error>?
    private var lastState: SnapshotState = .missing

    public init(profile: ServerProfile, cacheRoot: URL? = nil) {
        self.profile = profile
        self.cacheRoot = cacheRoot ?? RemoteSnapshot.defaultCacheRoot
    }

    public static var defaultCacheRoot: URL {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("Talaria", isDirectory: true)
    }

    public nonisolated func localPath() -> URL {
        // The actor's cacheRoot is set at init time; reading it from a
        // nonisolated context is safe because it's a let-bound URL on the
        // enclosing actor instance (URL is Sendable).
        let directory = cacheRoot
            .appendingPathComponent(profile.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("state.db", isDirectory: false)
    }

    public func currentState() async -> SnapshotState {
        let observed = currentObservedState()
        lastState = observed
        return observed
    }

    public func ageSeconds() async -> Int? {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: localPath().path),
            let modificationDate = attrs[.modificationDate] as? Date
        else {
            return nil
        }
        return max(0, Int(Date().timeIntervalSince(modificationDate)))
    }

    public func subscribe() -> AsyncStream<SnapshotState> {
        let token = UUID()
        let initial = currentObservedState()
        lastState = initial
        var capturedContinuation: AsyncStream<SnapshotState>.Continuation!
        let stream = AsyncStream<SnapshotState> { continuation in
            capturedContinuation = continuation
        }
        capturedContinuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(token: token) }
        }
        subscribers[token] = capturedContinuation
        capturedContinuation.yield(initial)
        return stream
    }

    /// Marks the local cache as stale so the next observer sees `.stale` and
    /// can decide to call `refresh()`. Used by `SessionManager` and
    /// `SessionsStore` when they observe a mutating side effect.
    public func invalidate() {
        // Backdate the cached file's mtime past the stale threshold so the
        // next observation reports `.stale`. Avoids deleting the file —
        // viewers can still query the last-known snapshot while a refresh
        // is in flight.
        let url = localPath()
        if FileManager.default.fileExists(atPath: url.path) {
            let staleDate = Date().addingTimeInterval(-Self.staleThreshold - 1)
            try? FileManager.default.setAttributes(
                [.modificationDate: staleDate],
                ofItemAtPath: url.path
            )
        }
        publish(currentObservedState())
    }

    public func refresh() async throws {
        if let existing = refreshTask {
            try await existing.value
            return
        }
        let task = Task { try await performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    private func performRefresh() async throws {
        guard profile.kind == .ssh else {
            throw RemoteSnapshotError.notRemoteProfile
        }
        guard let host = profile.host, !host.isEmpty else {
            throw RemoteSnapshotError.missingHost
        }

        publish(.refreshing)

        let remoteDB = remoteStateDBPath()
        let remoteTmp = "/tmp/talaria-snapshot-\(UUID().uuidString).db"
        let localURL = localPath()
        try ensureDirectory(localURL.deletingLastPathComponent())

        do {
            do {
                try await runBackup(host: host, remoteDB: remoteDB, remoteTmp: remoteTmp)
            } catch {
                // sqlite3 .backup may have created (or partially created) the
                // tmp file before failing — best-effort cleanup so the host
                // doesn't accumulate leftovers across timeouts and ssh drops.
                await runRemoteCleanup(host: host, remoteTmp: remoteTmp)
                throw error
            }
            do {
                try await runFetch(host: host, remoteTmp: remoteTmp, localURL: localURL)
            } catch {
                await runRemoteCleanup(host: host, remoteTmp: remoteTmp)
                throw error
            }
            await runRemoteCleanup(host: host, remoteTmp: remoteTmp)
            publish(currentObservedState())
        } catch let snapshotError as RemoteSnapshotError {
            publish(.error(snapshotError.errorDescription ?? "snapshot refresh failed"))
            throw snapshotError
        } catch {
            publish(.error(error.localizedDescription))
            throw error
        }
    }

    private func runBackup(host: String, remoteDB: String, remoteTmp: String) async throws {
        let cmd = Self.backupCommand(remoteDB: remoteDB, remoteTmp: remoteTmp)
        // The cmd is a fully-built shell line; ssh concatenates its post-host
        // arguments with spaces and hands the result to the remote login
        // shell, which then parses quoting/expansion. Wrapping `cmd` in
        // another `shellQuote` here would make the remote shell see the whole
        // thing as one literal token and try to exec it as a binary.
        let arguments = sshBaseArguments(host: host) + [cmd]
        let result = try await OneShotProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: arguments,
            timeout: 30
        )
        if result.timedOut {
            throw RemoteSnapshotError.sshFailed(.commandTimeout("ssh sqlite3 .backup timed out after 30s"))
        }
        if result.exitCode != 0 {
            let classified = SSHTransport.classifyStderr(result.stderr)
            if case .other = classified {
                throw RemoteSnapshotError.sqlite3Failed(result.stderr.isEmpty ? result.stdout : result.stderr)
            }
            throw RemoteSnapshotError.sshFailed(classified)
        }
    }

    private func runFetch(host: String, remoteTmp: String, localURL: URL) async throws {
        // sftp `-b -` reads a batched command list from stdin. We only need a
        // single `get` so this stays one round-trip.
        var arguments: [String] = []
        if let port = profile.port {
            arguments += ["-P", String(port)]
        }
        if let identityFile = profile.identityFile {
            arguments += ["-i", identityFile]
        }
        arguments += ["-b", "-"]
        let destination = profile.user.map { "\($0)@\(host)" } ?? host
        arguments.append(destination)

        // Download to a sibling tmp file then atomically rename, so any
        // SessionsBrowser query still holding an open handle to the old
        // state.db keeps reading the previous inode instead of tripping on
        // torn pages mid-transfer. The rename is on the same filesystem
        // (same parent directory) so it's truly atomic.
        let tmpURL = localURL.appendingPathExtension("downloading-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: tmpURL)

        let batch = Self.sftpGetCommand(remoteTmp: remoteTmp, localPath: tmpURL.path) + "\n"
        let stdin = Data(batch.utf8)

        let result = try await OneShotProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/sftp"),
            arguments: arguments,
            stdin: stdin,
            timeout: 60
        )
        if result.timedOut {
            try? FileManager.default.removeItem(at: tmpURL)
            throw RemoteSnapshotError.sshFailed(.commandTimeout("sftp get timed out after 60s"))
        }
        if result.exitCode != 0 {
            try? FileManager.default.removeItem(at: tmpURL)
            let stderr = result.stderr.isEmpty ? result.stdout : result.stderr
            throw RemoteSnapshotError.sftpFailed(stderr)
        }
        guard FileManager.default.fileExists(atPath: tmpURL.path) else {
            throw RemoteSnapshotError.sftpFailed("sftp succeeded but local file is missing at \(tmpURL.path)")
        }
        do {
            if FileManager.default.fileExists(atPath: localURL.path) {
                // `replaceItemAt` is atomic on the same filesystem, but it
                // requires the destination to *already* exist (otherwise it
                // throws "file doesn't exist"). For the steady-state refresh
                // path this is what we want — the open SQLite handle keeps
                // reading the old inode while the swap happens.
                _ = try FileManager.default.replaceItemAt(localURL, withItemAt: tmpURL)
            } else {
                // First refresh for a profile, or after the cache dir was
                // cleared: there's nothing to replace. A plain rename installs
                // the snapshot. Same-directory rename is still atomic.
                try FileManager.default.moveItem(at: tmpURL, to: localURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw RemoteSnapshotError.ioFailed("rename \(tmpURL.lastPathComponent) → \(localURL.lastPathComponent) failed: \(error.localizedDescription)")
        }
    }

    private func runRemoteCleanup(host: String, remoteTmp: String) async {
        let cmd = Self.cleanupCommand(remoteTmp: remoteTmp)
        let arguments = sshBaseArguments(host: host) + [cmd]
        // Cleanup failures (including timeouts) are best-effort — we leave the
        // temp file rather than surfacing an error mid-refresh. The remote
        // path uses a UUID so collisions don't recur.
        _ = try? await OneShotProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: arguments,
            timeout: 15
        )
    }

    /// Visible for testing. Builds the remote shell line that runs
    /// `sqlite3 <DB> ".backup <TMP>"`. The DB path is double-quoted so
    /// `$HOME` expands on the remote shell; the tmp path is single-quoted
    /// because it's an absolute literal we control.
    static func backupCommand(remoteDB: String, remoteTmp: String) -> String {
        let quotedRemoteDB = SSHTransport.shellDoubleQuoteAllowingExpansion(remoteDB)
        let quotedRemoteTmp = SSHTransport.shellQuote(remoteTmp)
        return "sqlite3 \(quotedRemoteDB) \".backup \(quotedRemoteTmp)\""
    }

    /// Visible for testing. Builds the remote shell line that removes the
    /// temporary snapshot file. Per-token quoting only — wrapping the whole
    /// command in another `shellQuote` would make the remote shell treat it
    /// as a single literal token and skip the actual `rm`.
    static func cleanupCommand(remoteTmp: String) -> String {
        "rm -f \(SSHTransport.shellQuote(remoteTmp))"
    }

    /// Visible for testing. Builds the single-line sftp batch command that
    /// pulls the remote temp file to the local cache path. Both paths are
    /// double-quoted so a space in either (e.g. a Mac user with a space in
    /// their short name → `/Users/John Doe/...`) doesn't get parsed as two
    /// sftp arguments. sftp uses backslash to escape inside double quotes.
    static func sftpGetCommand(remoteTmp: String, localPath: String) -> String {
        "get \(sftpQuote(remoteTmp)) \(sftpQuote(localPath))"
    }

    private static func sftpQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func sshBaseArguments(host: String) -> [String] {
        var arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
        ]
        if let port = profile.port {
            arguments += ["-p", String(port)]
        }
        if let identityFile = profile.identityFile {
            arguments += ["-i", identityFile]
        }
        let destination = profile.user.map { "\($0)@\(host)" } ?? host
        arguments += ["--", destination]
        return arguments
    }

    private func remoteStateDBPath() -> String {
        Self.remoteStateDBPath(hermesHome: profile.hermesHome)
    }

    /// Visible for testing. Resolves the remote `state.db` path that the
    /// backup command will reference, normalizing `~` prefixes to `$HOME`
    /// because the remote shell sees the path inside double quotes (so `~`
    /// would be taken literally).
    static func remoteStateDBPath(hermesHome: String?) -> String {
        if let hermesHome, !hermesHome.isEmpty {
            let normalized = hermesHome.hasPrefix("~")
                ? "$HOME" + String(hermesHome.dropFirst())
                : hermesHome
            return normalized.trimmingCharacters(in: ["/"]).isEmpty
                ? "/state.db"
                : "\(normalized.trimmingTrailingSlashes())/state.db"
        }
        return "$HOME/.hermes/state.db"
    }

    private func ensureDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw RemoteSnapshotError.ioFailed(error.localizedDescription)
        }
    }

    private func currentObservedState() -> SnapshotState {
        let url = localPath()
        guard
            FileManager.default.fileExists(atPath: url.path),
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let modificationDate = attrs[.modificationDate] as? Date
        else {
            return .missing
        }
        let age = max(0, Date().timeIntervalSince(modificationDate))
        if age <= Self.staleThreshold {
            return .fresh(ageSeconds: Int(age))
        }
        return .stale(ageSeconds: Int(age))
    }

    private func publish(_ state: SnapshotState) {
        lastState = state
        for continuation in subscribers.values {
            continuation.yield(state)
        }
    }

    private func removeSubscriber(token: UUID) {
        subscribers.removeValue(forKey: token)
    }

}

private extension String {
    func trimmingTrailingSlashes() -> String {
        var s = self
        while s.hasSuffix("/") {
            s.removeLast()
        }
        return s
    }
}
#endif

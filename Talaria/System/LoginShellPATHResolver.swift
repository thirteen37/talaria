import Foundation

// Apps launched outside a terminal inherit only a minimal PATH. We probe the
// user's login shell to discover where their CLI tools (like `hermes`) actually
// live. The probe is deferred so it never blocks view construction; the
// resolved value is cached to UserDefaults so subsequent launches are instant.
actor LoginShellPATHResolver {
    static let shared = LoginShellPATHResolver()

    private static let cacheKey = "talaria.loginShellPATH"
    private static let hermesHomeCacheKey = "talaria.loginShellHermesHome"

    /// Synchronous accessor for the HERMES_HOME the user's login shell exposes
    /// (when set). Read from UserDefaults so the Logs view can pick it up
    /// without awaiting an async probe. Returns nil when the probe hasn't run
    /// yet, when the variable is unset on the user's shell, or when the probe
    /// produced an empty value. Always reflects the most recent successful
    /// probe — `warm()` (fired from app launch) refreshes it on every run.
    static func cachedHermesHome() -> String? {
        let value = UserDefaults.standard.string(forKey: hermesHomeCacheKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    // Distinct from `resolved(nil)`: `unresolved` means the probe hasn't run
    // yet (or the previous launch never persisted anything to UserDefaults).
    // Caching a nil result is important — without it, every failed probe on a
    // slow/broken interactive shell would re-spawn a 2-second login shell on
    // each resolve() call.
    private enum CacheState {
        case unresolved
        case resolved(String?)
    }

    private var state: CacheState
    private var probeTask: Task<String?, Never>?

    init(initialCached: String? = UserDefaults.standard.string(forKey: LoginShellPATHResolver.cacheKey)) {
        // If UserDefaults has a value, treat it as resolved. If not, leave
        // unresolved so the first resolve() actually probes; we don't
        // negative-cache across launches since the user may have fixed their
        // shell config since.
        if let initialCached {
            self.state = .resolved(initialCached)
        } else {
            self.state = .unresolved
        }
    }

    // Cheap, non-isolated entry point so callers can fire-and-forget at startup
    // to populate the cache without ever awaiting on the main thread.
    nonisolated func warm() {
        Task.detached(priority: .utility) { [self] in
            _ = await self.resolve()
        }
    }

    func resolve() async -> String? {
        if case let .resolved(value) = state {
            return value
        }
        if let inflight = probeTask {
            return await inflight.value
        }
        let task = Task.detached(priority: .userInitiated) { Self.runProbe() }
        probeTask = task
        let result = await task.value
        probeTask = nil
        state = .resolved(result)
        if let result {
            UserDefaults.standard.set(result, forKey: Self.cacheKey)
        }
        return result
    }

    func extraEnv() async -> [String: String] {
        guard let path = await resolve() else {
            return [:]
        }
        return ["PATH": path]
    }

    private static let beginMarker = "__TALARIA_PATH_BEGIN__"
    private static let endMarker = "__TALARIA_PATH_END__"
    private static let beginHomeMarker = "__TALARIA_HOME_BEGIN__"
    private static let endHomeMarker = "__TALARIA_HOME_END__"

    private static func runProbe() -> String? {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        // Wrap PATH (and opportunistically HERMES_HOME) in markers so any
        // rc-file chatter on stdout (greetings, version banners) doesn't
        // pollute the parsed values. Discard stderr entirely: an undrained
        // pipe blocks the shell once the kernel buffer fills (oh-my-zsh,
        // nvm/pyenv/asdf init, deprecation warnings, etc.), which would
        // fail the probe. HERMES_HOME defaults to empty when unset so the
        // single printf works regardless of whether the user exports it;
        // the Logs view falls back to `~/.hermes` when nothing comes back.
        process.arguments = [
            "-ilc",
            "printf '%s%s%s%s%s%s' '\(beginMarker)' \"$PATH\" '\(endMarker)' '\(beginHomeMarker)' \"${HERMES_HOME:-}\" '\(endHomeMarker)'",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        // Drain stdout incrementally. macOS pipe buffers are ~64KB; verbose
        // rc files (oh-my-zsh banners, asdf/nvm init logs) can fill that
        // before the printf at the tail of the command runs, which would
        // block the shell and time out our probe.
        let buffer = ProbeBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                buffer.append(data)
            }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        // 10s — heavy interactive-shell configs (zgenom/oh-my-zsh + mise/asdf
        // hooks, work tooling that injects credentials, etc.) routinely take
        // 2-4s to finish sourcing rc files. 2s SIGTERMed the shell before it
        // could print PATH, which silently fell admin runs back to
        // ProcessInfo's minimal PATH and surfaced as `env: hermes: No such
        // file or directory`. The probe is async/background and only runs
        // once per app session, so the longer cap doesn't block UI.
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        let trailing = pipe.fileHandleForReading.readDataToEndOfFile()
        buffer.append(trailing)

        let output = String(decoding: buffer.snapshot(), as: UTF8.self)

        // Opportunistically refresh the HERMES_HOME cache from the same probe.
        // Independent of PATH parsing — even if the user's shell exports a
        // weird PATH we still want to surface HERMES_HOME when it's present,
        // and vice versa.
        if let beginHome = output.range(of: beginHomeMarker),
           let endHome = output.range(of: endHomeMarker, range: beginHome.upperBound..<output.endIndex) {
            let home = String(output[beginHome.upperBound..<endHome.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if home.isEmpty {
                UserDefaults.standard.removeObject(forKey: hermesHomeCacheKey)
            } else {
                UserDefaults.standard.set(home, forKey: hermesHomeCacheKey)
            }
        }

        guard let begin = output.range(of: beginMarker),
              let end = output.range(of: endMarker, range: begin.upperBound..<output.endIndex) else {
            return nil
        }
        let path = String(output[begin.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}

// Thread-safe append-only buffer for the stdout readabilityHandler, which is
// called from a Foundation-owned dispatch queue.
private final class ProbeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

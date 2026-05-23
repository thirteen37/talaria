import Foundation

// Apps launched outside a terminal inherit only a minimal PATH. We probe the
// user's login shell to discover where their CLI tools (like `hermes`) actually
// live. The probe is deferred so it never blocks view construction; the
// resolved value is cached to UserDefaults so subsequent launches are instant.
actor LoginShellPATHResolver {
    static let shared = LoginShellPATHResolver()

    private static let cacheKey = "talaria.loginShellPATH"

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

    private static func runProbe() -> String? {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        // Wrap PATH in markers so any rc-file chatter on stdout (greetings,
        // version banners) doesn't pollute the parsed value. Discard stderr
        // entirely: an undrained pipe blocks the shell once the kernel buffer
        // fills (oh-my-zsh, nvm/pyenv/asdf init, deprecation warnings, etc.),
        // which would fail the probe.
        process.arguments = [
            "-ilc",
            "printf '%s%s%s' '\(beginMarker)' \"$PATH\" '\(endMarker)'",
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
        let deadline = Date().addingTimeInterval(2)
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

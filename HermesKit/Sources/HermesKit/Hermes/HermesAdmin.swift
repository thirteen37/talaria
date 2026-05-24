import Foundation

public struct HermesAdminCommand: Sendable {
    public var arguments: [String]
    public var environment: [String: String]

    public init(arguments: [String], environment: [String: String] = [:]) {
        self.arguments = arguments
        self.environment = environment
    }
}

public struct HermesAdminResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum AdminEvent: Sendable, Equatable {
    case stdoutLine(String)
    case stderrLine(String)
    case exit(Int32)
}

public protocol HermesAdminRunning: Sendable {
    func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult
    func runStream(_ command: HermesAdminCommand) -> AsyncThrowingStream<AdminEvent, Error>
}

public extension HermesAdminRunning {
    // Default fallback for one-shot runners: drains the captured output once
    // the child has exited, then synthesises line events. Loses stdout/stderr
    // interleaving; concrete runners that want true live streaming should
    // override this method.
    func runStream(_ command: HermesAdminCommand) -> AsyncThrowingStream<AdminEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await self.run(command)
                    for line in Self.splitIntoLines(result.stdout) {
                        continuation.yield(.stdoutLine(line))
                    }
                    for line in Self.splitIntoLines(result.stderr) {
                        continuation.yield(.stderrLine(line))
                    }
                    continuation.yield(.exit(result.exitCode))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @discardableResult
    func renameSession(_ id: SessionId, to title: String) async throws -> HermesAdminResult {
        // `--` separator so a title or id starting with `-` isn't interpreted
        // as a CLI flag by hermes' argparse.
        try await run(HermesAdminCommand(arguments: ["sessions", "rename", "--", id, title]))
    }

    @discardableResult
    func deleteSession(_ id: SessionId) async throws -> HermesAdminResult {
        try await run(HermesAdminCommand(arguments: ["sessions", "delete", "--yes", "--", id]))
    }

    static func splitIntoLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n"), lines.last == "" {
            lines.removeLast()
        }
        return lines
    }
}

#if os(macOS)
public struct LocalHermesAdminRunner: HermesAdminRunning {
    /// Launcher that actually gets spawned. Defaults to `/usr/bin/env` so the
    /// resolved login-shell PATH (injected by `PathAwareHermesAdminRunner`) is
    /// honored when `argumentPrefix` is a bare name like `["hermes"]`. Tests
    /// substitute a different launcher (e.g. `/bin/sh`) via the test-seam init.
    public var executableURL: URL
    /// Arguments prepended to each command's `arguments`. In production this is
    /// `[profile.hermesPath]` so the spawned `env` invocation matches the
    /// session transport's `env <hermesPath> acp …` shape — sessions and admin
    /// must agree on which binary to launch, or the user sees `env: hermes: No
    /// such file or directory` from admin only when their profile points at an
    /// absolute path.
    public var argumentPrefix: [String]
    /// Baseline environment merged with each command's environment. Lets the
    /// caller seed values that are stable per-runner (e.g. `HERMES_HOME` from
    /// the profile) without re-passing them through every `HermesAdminCommand`.
    public var baseEnvironment: [String: String]

    /// Production init: invokes `/usr/bin/env <hermesPath> <args>`. Mirrors the
    /// session transport so PATH resolution and absolute-path handling behave
    /// identically across the chat and Manage surfaces.
    public init(hermesPath: String = "hermes", environment: [String: String] = [:]) {
        self.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        self.argumentPrefix = [hermesPath]
        self.baseEnvironment = environment
    }

    /// Test-only seam: spawns `executableURL` directly with `argumentPrefix +
    /// command.arguments`. Avoids relying on `/usr/bin/env` and a real hermes
    /// binary in the test target.
    public init(executableURL: URL, argumentPrefix: [String] = [], environment: [String: String] = [:]) {
        self.executableURL = executableURL
        self.argumentPrefix = argumentPrefix
        self.baseEnvironment = environment
    }

    public func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = argumentPrefix + command.arguments
        process.environment = mergedEnvironment(command: command)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let stdoutReader = ProcessOutputReader(handle: stdout.fileHandleForReading)
        let stderrReader = ProcessOutputReader(handle: stderr.fileHandleForReading)
        var stdoutTask: Task<Data, Never>?
        var stderrTask: Task<Data, Never>?

        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume(returning: ())
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }

            stdoutTask = Task.detached(priority: .userInitiated) {
                stdoutReader.readToEnd()
            }
            stderrTask = Task.detached(priority: .userInitiated) {
                stderrReader.readToEnd()
            }
        }
        let stdoutData = await stdoutTask?.value ?? Data()
        let stderrData = await stderrTask?.value ?? Data()

        return HermesAdminResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    public func runStream(_ command: HermesAdminCommand) -> AsyncThrowingStream<AdminEvent, Error> {
        let executableURL = executableURL
        let argumentPrefix = argumentPrefix
        let mergedEnvironment = mergedEnvironment(command: command)
        return AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = argumentPrefix + command.arguments
            process.environment = mergedEnvironment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdoutReader = AdminLineReader(handle: stdoutPipe.fileHandleForReading, label: "stdout") { line in
                continuation.yield(.stdoutLine(line))
            }
            let stderrReader = AdminLineReader(handle: stderrPipe.fileHandleForReading, label: "stderr") { line in
                continuation.yield(.stderrLine(line))
            }

            process.terminationHandler = { proc in
                // Drain any data still queued on the readers (and the trailing
                // partial line) before announcing exit, so consumers see all
                // output before `.exit`.
                stdoutReader.finish()
                stderrReader.finish()
                continuation.yield(.exit(proc.terminationStatus))
                continuation.finish()
            }

            continuation.onTermination = { _ in
                if process.isRunning {
                    process.terminate()
                }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
                return
            }

            stdoutReader.start()
            stderrReader.start()
        }
    }

    /// Layer the three env sources so command-specific keys win over the
    /// runner's baseline (e.g. profile HERMES_HOME), and either of those wins
    /// over whatever the host process inherited. Without this layering an
    /// ambient PATH on the host process would shadow the resolved login-shell
    /// PATH that `PathAwareHermesAdminRunner` injects per-call.
    private func mergedEnvironment(command: HermesAdminCommand) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in baseEnvironment {
            env[key] = value
        }
        for (key, value) in command.environment {
            env[key] = value
        }
        return env
    }
}

private final class ProcessOutputReader: @unchecked Sendable {
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
    }

    func readToEnd() -> Data {
        handle.readDataToEndOfFile()
    }
}

/// Line-buffered reader over a `FileHandle`. The `readabilityHandler` drains
/// `availableData` on Foundation's source queue; we then hop onto a dedicated
/// serial queue so newline splitting and continuation yields are serialised
/// per stream. `finish()` is called synchronously from the process's
/// termination handler — it tears down the source, reads any trailing buffered
/// bytes, and flushes the partial line, guaranteeing all output is emitted
/// before `.exit`.
final class AdminLineReader: @unchecked Sendable {
    private let handle: FileHandle
    private let onLine: (String) -> Void
    private let queue: DispatchQueue
    private var buffer = Data()
    private var finished = false

    init(handle: FileHandle, label: String, onLine: @escaping (String) -> Void) {
        self.handle = handle
        self.onLine = onLine
        self.queue = DispatchQueue(label: "com.talaria.HermesKit.AdminLineReader.\(label)")
    }

    func start() {
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self else { return }
            if data.isEmpty {
                self.queue.async {
                    self.handle.readabilityHandler = nil
                }
                return
            }
            self.queue.async {
                self.append(data)
            }
        }
    }

    func finish() {
        queue.sync {
            guard !finished else { return }
            handle.readabilityHandler = nil
            let trailing = handle.readDataToEndOfFile()
            if !trailing.isEmpty {
                append(trailing)
            }
            if !buffer.isEmpty {
                onLine(String(decoding: buffer, as: UTF8.self))
                buffer.removeAll()
            }
            finished = true
        }
    }

    private func append(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            var end = nl
            if end > buffer.startIndex, buffer[end - 1] == 0x0D {
                end -= 1
            }
            let line = buffer.subdata(in: buffer.startIndex..<end)
            onLine(String(decoding: line, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
    }
}
#endif

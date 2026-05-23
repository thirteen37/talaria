#if os(macOS)
import Foundation

/// One-shot process runner — spawns a child, captures stdout/stderr to
/// completion, and returns the exit code. Used by SSH probes, the Hermes
/// version probe, and the remote SQLite snapshot pipeline. Differs from
/// ``LocalProcessTransport`` in that it doesn't expose a duplex stream; the
/// child is expected to terminate on its own (with an optional timeout) and
/// we only care about the captured buffers.
public enum OneShotProcess {
    public struct Result: Sendable, Equatable {
        public var exitCode: Int32
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool

        public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
            self.timedOut = timedOut
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case spawnFailed(String)
    }

    public static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> Result {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            process.environment = environment.merging(ProcessInfo.processInfo.environment) { local, _ in local }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        let stdoutReader = ProcessOutputReader(handle: stdoutPipe.fileHandleForReading)
        let stderrReader = ProcessOutputReader(handle: stderrPipe.fileHandleForReading)

        do {
            try process.run()
        } catch {
            throw Failure.spawnFailed(error.localizedDescription)
        }

        if let stdin {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
        }
        try? stdinPipe.fileHandleForWriting.close()

        let stdoutTask = Task.detached(priority: .userInitiated) { stdoutReader.readToEnd() }
        let stderrTask = Task.detached(priority: .userInitiated) { stderrReader.readToEnd() }

        var timedOut = false
        if let timeout {
            let exited = await pollUntilExit(process, timeout: timeout)
            if !exited {
                timedOut = true
                kill(process.processIdentifier, SIGKILL)
                _ = await pollUntilExit(process, timeout: 1.0)
            }
        } else {
            await pollUntilExitForever(process)
        }

        let stdout = await stdoutTask.value
        let stderr = await stderrTask.value

        return Result(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self),
            timedOut: timedOut
        )
    }

    private static func pollUntilExit(_ proc: Process, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let deadline = Date().addingTimeInterval(timeout)
                while proc.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                continuation.resume(returning: !proc.isRunning)
            }
        }
    }

    private static func pollUntilExitForever(_ proc: Process) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                while proc.isRunning {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                continuation.resume()
            }
        }
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
#endif

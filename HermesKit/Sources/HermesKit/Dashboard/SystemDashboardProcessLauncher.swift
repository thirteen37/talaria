#if os(macOS)
import Foundation

/// Production `DashboardProcessLauncher` that drives a `Process`. macOS-only
/// because `Process` is unavailable on iOS — the iOS path is expected to
/// land alongside the NIO-SSH port-forwarding implementation when we plumb
/// dashboard mode for remote profiles on the iPad.
public struct SystemDashboardProcessLauncher: DashboardProcessLauncher {
    public init() {}

    public func launch(spec: DashboardSpawnSpec) async throws -> any DashboardProcess {
        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        if !spec.environment.isEmpty {
            process.environment = spec.environment.merging(
                ProcessInfo.processInfo.environment,
                uniquingKeysWith: { local, _ in local }
            )
        }

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        // We don't read stdout — the dashboard logs uvicorn boot lines there
        // but they're noise. Discard via /dev/null so the OS pipe buffer
        // doesn't fill and block the child.
        process.standardOutput = FileHandle.nullDevice

        var stderrCont: AsyncStream<String>.Continuation?
        let stderrStream = AsyncStream<String> { c in stderrCont = c }
        let stderrContinuation = stderrCont!

        let stderrReader = stderrPipe.fileHandleForReading
        stderrReader.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            if let line = String(data: data, encoding: .utf8) {
                stderrContinuation.yield(line)
            }
        }

        try process.run()

        return SystemDashboardProcess(
            process: process,
            stderrPipe: stderrPipe,
            stderrStream: stderrStream,
            stderrContinuation: stderrContinuation
        )
    }
}

final class SystemDashboardProcess: DashboardProcess, @unchecked Sendable {
    private let process: Process
    let stderr: AsyncStream<String>
    private let stderrPipe: Pipe
    private let stderrContinuation: AsyncStream<String>.Continuation
    private let exitStream: AsyncStream<Int32>
    private let exitContinuation: AsyncStream<Int32>.Continuation
    private let terminationHandled = TerminationBox()
    private let exitCode = ExitCodeBox()

    init(
        process: Process,
        stderrPipe: Pipe,
        stderrStream: AsyncStream<String>,
        stderrContinuation: AsyncStream<String>.Continuation
    ) {
        self.process = process
        self.stderr = stderrStream
        self.stderrPipe = stderrPipe
        self.stderrContinuation = stderrContinuation
        var capturedExit: AsyncStream<Int32>.Continuation?
        self.exitStream = AsyncStream<Int32> { c in capturedExit = c }
        self.exitContinuation = capturedExit!

        // Drain whatever's left in the pipe after the process exits — the
        // readabilityHandler races with terminationHandler and finishing the
        // stderr continuation too early drops the last write (typically the
        // line we most need to surface: the import error or the bind
        // failure). Detach the readabilityHandler first so we own all reads.
        process.terminationHandler = { [stderrPipe, stderrContinuation, exitContinuation = self.exitContinuation, terminationHandled, exitCode] proc in
            guard terminationHandled.markIfFirst() else { return }
            let reader = stderrPipe.fileHandleForReading
            reader.readabilityHandler = nil
            let remaining = (try? reader.readToEnd()) ?? Data()
            if !remaining.isEmpty, let line = String(data: remaining, encoding: .utf8) {
                stderrContinuation.yield(line)
            }
            stderrContinuation.finish()
            exitCode.publish(proc.terminationStatus)
            exitContinuation.yield(proc.terminationStatus)
            exitContinuation.finish()
        }
    }

    func terminate() async {
        guard process.isRunning else { return }
        process.terminate() // SIGTERM
        // Give the process a short window to flush stderr and exit gracefully
        // before escalating. Most well-behaved daemons respond within ms;
        // a stuck one warrants SIGKILL.
        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        _ = await waitForExit()
    }

    func waitForExit() async -> Int32 {
        for await code in exitStream {
            return code
        }
        return process.terminationStatus
    }

    func exitCodeIfAvailable() async -> Int32? {
        exitCode.value
    }
}

/// One-shot flag so termination side-effects (closing the stderr stream,
/// publishing the exit code) only fire once across `terminationHandler`
/// callbacks and explicit `terminate()` calls.
final class TerminationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func markIfFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

final class ExitCodeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int32?

    var value: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return code
    }

    func publish(_ newValue: Int32) {
        lock.lock()
        defer { lock.unlock() }
        code = newValue
    }
}
#endif

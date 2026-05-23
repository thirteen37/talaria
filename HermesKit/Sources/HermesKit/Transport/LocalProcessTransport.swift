#if os(macOS)
import Foundation

public final class LocalProcessTransport: Transport, @unchecked Sendable {
    public let inbound: AsyncThrowingStream<Data, Error>

    private let process: Process
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let stderrPipe = Pipe()
    private let inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let stderrRing = StderrRingBuffer()
    private let readQueue = DispatchQueue(label: "com.talaria.HermesKit.LocalProcessTransport.read")
    private let writeQueue = DispatchQueue(label: "com.talaria.HermesKit.LocalProcessTransport.write")
    private let lock = NSLock()
    private var started = false
    private var closed = false
    private var inboundFinished = false

    public init(executableURL: URL, arguments: [String] = [], environment: [String: String] = [:]) {
        self.process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment.merging(ProcessInfo.processInfo.environment) { local, _ in local }
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = stderrPipe

        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        self.inbound = AsyncThrowingStream { continuation in
            captured = continuation
        }
        self.inboundContinuation = captured!
    }

    public convenience init(hermesPath: String = "/usr/bin/env", hermesHome: String? = nil) {
        var environment: [String: String] = [:]
        if let hermesHome {
            environment["HERMES_HOME"] = hermesHome
        }
        self.init(executableURL: URL(fileURLWithPath: hermesPath), arguments: hermesPath == "/usr/bin/env" ? ["hermes", "acp"] : ["acp"], environment: environment)
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !started else {
            throw TransportError.processAlreadyStarted
        }
        started = true
        closed = false

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            // Foundation invokes this handler on its own dispatch source.
            // We must read `handle.availableData` synchronously here so the
            // source rearms; deferring the read to another queue leaves the
            // FD buffered but the GCD source un-rearmed, and the handler
            // never fires again.
            let data = handle.availableData
            guard let transport = self else {
                return
            }
            if data.isEmpty {
                transport.readQueue.async { [weak transport] in
                    guard let transport, !transport.inboundFinished else {
                        return
                    }
                    transport.outputPipe.fileHandleForReading.readabilityHandler = nil
                    if transport.process.isRunning {
                        transport.finishOrTerminateAfterStdoutEOF()
                    } else {
                        transport.finishAfterProcessTerminationOnReadQueue()
                    }
                }
            } else {
                transport.readQueue.async { [weak transport] in
                    guard let transport, !transport.inboundFinished else {
                        return
                    }
                    transport.inboundContinuation.yield(data)
                }
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let transport = self, !data.isEmpty else {
                return
            }
            transport.readQueue.async { [weak transport] in
                transport?.stderrRing.append(data)
            }
        }

        process.terminationHandler = { [weak self] _ in
            guard let transport = self else {
                return
            }
            transport.readQueue.async { [weak transport] in
                guard let transport else {
                    return
                }

                transport.finishAfterProcessTerminationOnReadQueue()
            }
        }

        do {
            try process.run()
        } catch {
            started = false
            closed = true
            readQueue.async { [weak self] in
                self?.finishInboundOnReadQueue()
            }
            throw TransportError.processDidNotStart(error.localizedDescription)
        }
    }

    public func send(_ data: Data) async throws {
        let state = stateForSend()

        guard state.didStart else {
            throw TransportError.processNotStarted
        }
        guard state.canSend else {
            throw TransportError.stdinClosed
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async { [weak self, inputPipe] in
                guard let self else {
                    continuation.resume(throwing: TransportError.transportClosed)
                    return
                }

                guard !self.isClosed() else {
                    continuation.resume(throwing: TransportError.stdinClosed)
                    return
                }

                do {
                    try inputPipe.fileHandleForWriting.write(contentsOf: data)
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: TransportError.writeFailed(error.localizedDescription))
                }
            }
        }
    }

    public func close() async {
        if markClosed() {
            return
        }

        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            // Wait for the child to actually exit before returning. Without
            // this, callers can't safely sequence dependent work that touches
            // shared state the child was writing to (e.g. a CLI subprocess
            // mutating the same SQLite DB).
            await waitUntilExit()
        } else {
            readQueue.async { [weak self] in
                self?.finishInboundOnReadQueue()
            }
        }
    }

    // SIGTERM should be enough for any well-behaved child, but if the process
    // ignores it (or is wedged), we don't want close() to hang the UI close
    // path forever. Wait up to 2 seconds, then escalate to SIGKILL.
    private static let terminateGracePeriod: TimeInterval = 2.0
    private static let killGracePeriod: TimeInterval = 1.0

    private func waitUntilExit() async {
        let proc = process
        if await Self.pollUntilExit(proc, timeout: Self.terminateGracePeriod) {
            return
        }
        kill(proc.processIdentifier, SIGKILL)
        _ = await Self.pollUntilExit(proc, timeout: Self.killGracePeriod)
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

    public func recentStderr() -> String {
        stderrRing.snapshot()
    }

    private func finishInboundOnReadQueue() {
        guard !inboundFinished else {
            return
        }
        inboundFinished = true
        inboundContinuation.finish()
    }

    private func finishAfterProcessTerminationOnReadQueue() {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let trailingOutput = outputPipe.fileHandleForReading.readDataToEndOfFile()
        if !trailingOutput.isEmpty, !inboundFinished {
            inboundContinuation.yield(trailingOutput)
        }

        let trailingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !trailingStderr.isEmpty {
            stderrRing.append(trailingStderr)
        }

        finishInboundOnReadQueue()
    }

    private func finishOrTerminateAfterStdoutEOF() {
        readQueue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self, !self.inboundFinished else {
                return
            }

            if self.process.isRunning {
                self.finishInboundOnReadQueue()
                self.process.terminate()
            } else {
                self.finishAfterProcessTerminationOnReadQueue()
            }
        }
    }

    private func stateForSend() -> (didStart: Bool, canSend: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let canSend = started && !closed && process.isRunning
        return (started, canSend)
    }

    private func isClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func markClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed {
            return true
        }
        closed = true
        return false
    }
}

private final class StderrRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let byteLimit: Int
    private var data = Data()

    init(byteLimit: Int = 64 * 1024) {
        self.byteLimit = byteLimit
    }

    func append(_ newData: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(newData)
        if data.count > byteLimit {
            data.removeFirst(data.count - byteLimit)
        }
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif

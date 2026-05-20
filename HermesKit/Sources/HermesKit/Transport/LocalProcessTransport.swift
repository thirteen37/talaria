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
    private let lock = NSLock()
    private var started = false

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

        outputPipe.fileHandleForReading.readabilityHandler = { [inboundContinuation] handle in
            let data = handle.availableData
            if data.isEmpty {
                inboundContinuation.finish()
            } else {
                inboundContinuation.yield(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [stderrRing] handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrRing.append(data)
            }
        }

        process.terminationHandler = { [inboundContinuation, outputPipe, stderrPipe] _ in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            inboundContinuation.finish()
        }

        do {
            try process.run()
        } catch {
            throw TransportError.processDidNotStart(error.localizedDescription)
        }
    }

    public func send(_ data: Data) async throws {
        try inputPipe.fileHandleForWriting.write(contentsOf: data)
    }

    public func close() async {
        inputPipe.fileHandleForWriting.closeFile()
        if process.isRunning {
            process.terminate()
        }
        inboundContinuation.finish()
    }

    public func recentStderr() -> String {
        stderrRing.snapshot()
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

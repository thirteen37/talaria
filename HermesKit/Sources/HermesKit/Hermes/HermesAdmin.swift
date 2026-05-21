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

public protocol HermesAdminRunning: Sendable {
    func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult
}

#if os(macOS)
public struct LocalHermesAdminRunner: HermesAdminRunning {
    public var hermesPath: String

    public init(hermesPath: String = "/usr/bin/env") {
        self.hermesPath = hermesPath
    }

    public func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hermesPath)
        process.arguments = hermesPath == "/usr/bin/env" ? ["hermes"] + command.arguments : command.arguments
        process.environment = command.environment.merging(ProcessInfo.processInfo.environment) { local, _ in local }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let stdoutBuffer = ProcessOutputBuffer()
        let stderrBuffer = ProcessOutputBuffer()
        let readQueue = DispatchQueue(label: "com.talaria.HermesKit.LocalHermesAdminRunner.read")

        stdout.fileHandleForReading.readabilityHandler = { handle in
            readQueue.async {
                let data = handle.availableData
                if !data.isEmpty {
                    stdoutBuffer.append(data)
                }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            readQueue.async {
                let data = handle.availableData
                if !data.isEmpty {
                    stderrBuffer.append(data)
                }
            }
        }

        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume(returning: ())
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        readQueue.sync {
            stdoutBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
            stderrBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
        }

        return HermesAdminResult(
            exitCode: process.terminationStatus,
            stdout: stdoutBuffer.string(),
            stderr: stderrBuffer.string()
        )
    }
}

private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        guard !newData.isEmpty else {
            return
        }
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(decoding: snapshot, as: UTF8.self)
    }
}
#endif

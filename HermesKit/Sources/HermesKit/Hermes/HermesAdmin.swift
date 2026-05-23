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

public extension HermesAdminRunning {
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

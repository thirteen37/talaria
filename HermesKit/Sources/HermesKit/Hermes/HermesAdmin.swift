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

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return HermesAdminResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }
}
#endif

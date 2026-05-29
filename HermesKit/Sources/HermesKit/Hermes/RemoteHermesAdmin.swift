#if os(macOS)
import Foundation

public struct RemoteHermesAdminRunner: HermesAdminRunning {
    public let profile: ServerProfile

    public init(profile: ServerProfile) {
        self.profile = profile
    }

    public func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult {
        guard profile.kind == .ssh, let host = profile.host, !host.isEmpty else {
            return HermesAdminResult(exitCode: 1, stdout: "", stderr: "profile is not an SSH profile")
        }

        let sshArgs = Self.sshArguments(host: host, command: command, profile: profile)

        let result = try await OneShotProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: sshArgs,
            timeout: 30
        )

        return HermesAdminResult(
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr
        )
    }

    public func runStream(_ command: HermesAdminCommand) -> AsyncThrowingStream<AdminEvent, Error> {
        AsyncThrowingStream { continuation in
            guard profile.kind == .ssh, let host = profile.host, !host.isEmpty else {
                continuation.yield(.stderrLine("profile is not an SSH profile"))
                continuation.yield(.exit(1))
                continuation.finish()
                return
            }

            let sshArgs = Self.sshArguments(host: host, command: command, profile: profile)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = sshArgs

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdoutReader = AdminLineReader(handle: stdoutPipe.fileHandleForReading, label: "ssh.stdout") { line in
                continuation.yield(.stdoutLine(line))
            }
            let stderrReader = AdminLineReader(handle: stderrPipe.fileHandleForReading, label: "ssh.stderr") { line in
                continuation.yield(.stderrLine(line))
            }

            process.terminationHandler = { proc in
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

    private static func sshArguments(host: String, command: HermesAdminCommand, profile: ServerProfile) -> [String] {
        var sshArgs: [String] = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
        ]
        if let port = profile.port {
            sshArgs += ["-p", String(port)]
        }
        if let identityFile = profile.identityFile {
            sshArgs += ["-i", identityFile]
        }
        let destination = profile.user.map { "\($0)@\(host)" } ?? host
        sshArgs += ["--", destination]

        // The wrapped `env COLUMNS=400 [HERMES_HOME=…] <hermesPath> <args…>`
        // remote line is built by the shared `buildHermesAdminRemoteCommand`
        // so the NIO-SSH admin runner sends a byte-identical command.
        sshArgs.append(buildHermesAdminRemoteCommand(profile: profile, command: command))
        return sshArgs
    }
}
#endif

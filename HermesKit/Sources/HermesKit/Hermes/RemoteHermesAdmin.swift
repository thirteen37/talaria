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

        // Always start with `env COLUMNS=400 …`. Rich on the remote falls back
        // to an 80-col layout under non-interactive ssh, which truncates table
        // cells (skill names, tool descriptions) into ellipsis-suffixed strings
        // the parsers can't recover from. Folding COLUMNS into the same env
        // prefix HERMES_HOME uses keeps the quoting logic in one place.
        var envAssignments: [String] = ["COLUMNS=400"]
        if let hermesHome = profile.hermesHome, !hermesHome.isEmpty {
            envAssignments.append("HERMES_HOME=\(hermesHome)")
        }
        var remoteParts: [String] = ["env"]
        remoteParts += envAssignments.map { SSHTransport.shellQuote($0) }
        remoteParts.append(SSHTransport.shellQuote(profile.hermesPath))
        remoteParts += command.arguments.map { SSHTransport.shellQuote($0) }
        let inner = remoteParts.joined(separator: " ")
        // Honor the profile's shell mode so users on hosts where ssh's
        // non-interactive PATH doesn't see `hermes` can opt into a login
        // shell wrapper (`bash -lc '...'`).
        let wrapped = profile.remoteShellMode.wrap(command: inner, customPrefix: profile.remoteShellPrefix)
        sshArgs.append(wrapped)
        return sshArgs
    }
}
#endif

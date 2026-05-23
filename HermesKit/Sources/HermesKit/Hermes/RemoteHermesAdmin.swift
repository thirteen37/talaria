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

        // Build remote command: env HERMES_HOME=... <hermesPath> <args...>
        var remoteParts: [String] = []
        if let hermesHome = profile.hermesHome, !hermesHome.isEmpty {
            remoteParts += ["env", SSHTransport.shellQuote("HERMES_HOME=\(hermesHome)")]
        }
        remoteParts.append(SSHTransport.shellQuote(profile.hermesPath))
        remoteParts += command.arguments.map { SSHTransport.shellQuote($0) }
        let remoteCommand = remoteParts.joined(separator: " ")
        sshArgs.append(remoteCommand)

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
}
#endif

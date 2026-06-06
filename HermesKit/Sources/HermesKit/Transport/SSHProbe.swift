#if os(macOS)
import Foundation

/// Stateless system-`ssh` helpers shared by the non-chat SSH surfaces (the
/// reachability probe, remote shell quoting, stderr classification). These used
/// to live on the chat `SSHTransport`; they outlived it when live chat moved to
/// the dashboard `/api/ws` gateway.
public enum SSHProbe {
    /// Opens a throwaway `ssh … printf ok` to confirm the host is reachable and
    /// auth/host-key succeed, classifying any failure into a typed
    /// ``SSHTransportError``. Used by the connectivity probe before a heavier
    /// command runs.
    public static func probeConnectivity(profile: ServerProfile, connectTimeout: Int = 5) async throws {
        guard profile.kind == .ssh, let host = profile.host, !host.isEmpty else {
            throw SSHTransportError.other("profile is not an SSH profile")
        }
        let arguments = probeArguments(
            host: host,
            user: profile.user,
            port: profile.port,
            identityFile: profile.identityFile,
            connectTimeout: connectTimeout
        )
        let result = try await OneShotProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: arguments,
            timeout: TimeInterval(connectTimeout) + 5
        )
        if result.exitCode == 0 {
            return
        }
        let stderr = result.stderr.isEmpty ? result.stdout : result.stderr
        throw SSHStderrClassifier.classify(stderr)
    }

    /// Quote a value for safe inclusion in a remote `sh -lc` command.
    public static func shellQuote(_ value: String) -> String {
        ShellQuoting.shellQuote(value)
    }

    /// Map raw `ssh` stderr to a typed ``SSHTransportError``.
    public static func classifyStderr(_ stderr: String) -> SSHTransportError {
        SSHStderrClassifier.classify(stderr)
    }

    static func probeArguments(
        host: String,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        connectTimeout: Int = 5
    ) -> [String] {
        var arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(connectTimeout)",
        ]
        if let port {
            arguments += ["-p", String(port)]
        }
        if let identityFile {
            arguments += ["-i", identityFile]
        }
        let destination = user.map { "\($0)@\(host)" } ?? host
        arguments += ["--", destination, "printf", "ok"]
        return arguments
    }
}

#endif

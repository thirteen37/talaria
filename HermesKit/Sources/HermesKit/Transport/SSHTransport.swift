#if os(macOS)
import Foundation

public enum SSHTransportError: Error, Equatable, Sendable, LocalizedError {
    case hostUnreachable(String)
    case authFailed(String)
    case hostKeyVerification(String)
    case commandTimeout(String)
    case other(String)

    public var message: String {
        switch self {
        case let .hostUnreachable(message),
             let .authFailed(message),
             let .hostKeyVerification(message),
             let .commandTimeout(message),
             let .other(message):
            return message
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .hostUnreachable(message): return "Host unreachable: \(message)"
        case let .authFailed(message): return "Authentication failed: \(message)"
        case let .hostKeyVerification(message): return "Host key verification failed: \(message)"
        case let .commandTimeout(message): return "SSH timed out: \(message)"
        case let .other(message): return message
        }
    }
}

public final class SSHTransport: Transport, @unchecked Sendable {
    public var inbound: AsyncThrowingStream<Data, Error> {
        processTransport.inbound
    }

    private let processTransport: LocalProcessTransport

    public init(
        host: String,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        hermesPath: String = "hermes",
        hermesHome: String? = nil
    ) {
        let arguments = Self.makeArguments(
            host: host,
            user: user,
            port: port,
            identityFile: identityFile,
            hermesPath: hermesPath,
            hermesHome: hermesHome
        )

        self.processTransport = LocalProcessTransport(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: arguments
        )
    }

    static func makeArguments(
        host: String,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        hermesPath: String = "hermes",
        hermesHome: String? = nil
    ) -> [String] {
        var arguments = ["-T", "-o", "BatchMode=yes"]
        if let port {
            arguments += ["-p", String(port)]
        }
        if let identityFile {
            arguments += ["-i", identityFile]
        }

        let destination = user.map { "\($0)@\(host)" } ?? host
        arguments += ["--", destination]
        if let hermesHome {
            arguments += ["env", shellQuote("HERMES_HOME=\(hermesHome)")]
        }
        arguments += [shellQuote(hermesPath), "acp"]
        return arguments
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

    static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else {
            return "''"
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Wraps a value in double quotes, escaping the characters that double
    /// quotes don't otherwise neutralize (`\`, `"`, `` ` ``) but **leaving
    /// `$` alone** so that the remote shell still expands `$HOME` and similar
    /// environment references. Single-quote wrapping (``shellQuote``) is
    /// preferred for literal values; reach for this only when you intentionally
    /// want the remote shell to expand variables.
    static func shellDoubleQuoteAllowingExpansion(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    public func start() throws {
        try processTransport.start()
    }

    public func send(_ data: Data) async throws {
        try await processTransport.send(data)
    }

    public func close() async {
        await processTransport.close()
    }

    public func recentStderr() -> String {
        processTransport.recentStderr()
    }

    /// Classifies the most recent stderr captured from the underlying ssh process.
    /// Useful when the ACP transport exits unexpectedly and we want a typed reason
    /// to display in the chat surface.
    public func classifyRecentStderr() -> SSHTransportError {
        Self.classifyStderr(recentStderr())
    }

    /// Best-effort static classifier — no platform calls, safe to unit-test.
    public static func classifyStderr(_ stderr: String) -> SSHTransportError {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .other("ssh exited without diagnostic output")
        }
        let lowered = trimmed.lowercased()
        if lowered.contains("host key verification failed") {
            return .hostKeyVerification(trimmed)
        }
        if lowered.contains("permission denied")
            || lowered.contains("publickey")
            || lowered.contains("no supported authentication methods") {
            return .authFailed(trimmed)
        }
        if lowered.contains("connection timed out")
            || lowered.contains("operation timed out") {
            return .commandTimeout(trimmed)
        }
        if lowered.contains("could not resolve hostname")
            || lowered.contains("name or service not known")
            || lowered.contains("no route to host")
            || lowered.contains("connection refused")
            || lowered.contains("network is unreachable") {
            return .hostUnreachable(trimmed)
        }
        return .other(trimmed)
    }

    /// Runs a non-interactive `ssh ... printf ok` against the profile to verify
    /// connectivity and authentication before spawning the long-lived ACP
    /// transport. Throws ``SSHTransportError`` with classified stderr on failure.
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
        throw classifyStderr(stderr)
    }
}
#endif

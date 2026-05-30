#if os(macOS)
import Foundation

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
        hermesHome: String? = nil,
        remoteShellMode: RemoteShellMode = .direct,
        remoteShellPrefix: String? = nil,
        hermesProfileName: String? = nil
    ) {
        let arguments = Self.makeArguments(
            host: host,
            user: user,
            port: port,
            identityFile: identityFile,
            hermesPath: hermesPath,
            hermesHome: hermesHome,
            remoteShellMode: remoteShellMode,
            remoteShellPrefix: remoteShellPrefix,
            hermesProfileName: hermesProfileName
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
        hermesHome: String? = nil,
        remoteShellMode: RemoteShellMode = .direct,
        remoteShellPrefix: String? = nil,
        hermesProfileName: String? = nil
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
        // Splitting the wrapped command across multiple argv tokens would
        // break the `<login-shell> -lc '<inner>'` form, since ssh joins
        // post-destination args with spaces before handing them to the
        // remote shell. Append as a single argv element — the same one the
        // NIO-SSH transport sends via ExecRequest.
        arguments.append(
            buildHermesRemoteCommand(
                hermesPath: hermesPath,
                hermesHome: hermesHome,
                remoteShellMode: remoteShellMode,
                remoteShellPrefix: remoteShellPrefix,
                hermesProfileName: hermesProfileName
            )
        )
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

    // Re-exposed on `SSHTransport` so the existing macOS callers
    // (RemoteSnapshot, RemoteHermesAdmin) keep compiling unchanged. The
    // canonical implementation lives in `ShellQuoting` so the NIO-SSH
    // transport can call it without crossing the macOS gate.
    static func shellQuote(_ value: String) -> String {
        ShellQuoting.shellQuote(value)
    }

    static func shellDoubleQuoteAllowingExpansion(_ value: String) -> String {
        ShellQuoting.shellDoubleQuoteAllowingExpansion(value)
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
        SSHStderrClassifier.classify(recentStderr())
    }

    /// Thin wrapper retained for source-compatibility with existing callers
    /// (RemoteSnapshot, tests). New code should prefer
    /// ``SSHStderrClassifier/classify(_:)`` directly so it stays callable on
    /// platforms where `SSHTransport` itself is unavailable.
    public static func classifyStderr(_ stderr: String) -> SSHTransportError {
        SSHStderrClassifier.classify(stderr)
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
        throw SSHStderrClassifier.classify(stderr)
    }
}
#endif

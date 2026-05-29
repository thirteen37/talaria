import Foundation

public struct HermesProbeResult: Equatable, Sendable {
    public var binaryPath: String
    public var version: HermesVersion
    public var versionRaw: String
    public var acpSupported: Bool

    public init(binaryPath: String, version: HermesVersion, versionRaw: String, acpSupported: Bool) {
        self.binaryPath = binaryPath
        self.version = version
        self.versionRaw = versionRaw
        self.acpSupported = acpSupported
    }
}

public enum HermesProbeError: Error, Equatable, Sendable {
    case binaryNotFound(String)
    case versionUnparseable(String)
    case probeFailed(String)
    case transportFailed(SSHTransportError)
}

#if os(macOS)
public enum HermesProbe {
    /// Minimum Hermes version we consider ACP-capable. Sprint 6 finalizes the
    /// real pin; for Sprint 4 we just record what we observed.
    public static let minimumACPVersion = HermesVersion(major: 0, minor: 0, patch: 0)

    public static func probe(profile: ServerProfile, timeout: TimeInterval = 10) async throws -> HermesProbeResult {
        let result: OneShotProcess.Result
        switch profile.kind {
        case .local:
            result = try await runLocal(profile: profile, timeout: timeout)
        case .ssh:
            try await SSHTransport.probeConnectivity(profile: profile)
            result = try await runOverSSH(profile: profile, timeout: timeout)
        }

        if result.timedOut {
            throw HermesProbeError.probeFailed("hermes --version timed out after \(Int(timeout))s")
        }
        if result.exitCode != 0 {
            let stderr = result.stderr.isEmpty ? result.stdout : result.stderr
            throw HermesProbeError.binaryNotFound(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return try parse(stdout: result.stdout)
    }

    /// Visible for testing — parses the captured stdout produced by
    /// `command -v hermes; hermes --version` (or the SSH equivalent).
    static func parse(stdout: String) throws -> HermesProbeResult {
        let lines = stdout
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else {
            throw HermesProbeError.versionUnparseable(stdout)
        }
        let binaryPath = lines[0]
        let versionLine = lines[1]
        guard let version = HermesVersion(versionLine) else {
            throw HermesProbeError.versionUnparseable(versionLine)
        }
        return HermesProbeResult(
            binaryPath: binaryPath,
            version: version,
            versionRaw: versionLine,
            acpSupported: version >= minimumACPVersion
        )
    }

    private static func runLocal(profile: ServerProfile, timeout: TimeInterval) async throws -> OneShotProcess.Result {
        // Run via the user's login shell so PATH-resolution / shell-builtins
        // behave the same way the user would expect from Terminal.
        let script = makeProbeScript(hermesPath: profile.hermesPath)
        do {
            return try await OneShotProcess.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-lc", script],
                environment: profile.env,
                timeout: timeout
            )
        } catch let failure as OneShotProcess.Failure {
            throw HermesProbeError.probeFailed(String(describing: failure))
        }
    }

    private static func runOverSSH(profile: ServerProfile, timeout: TimeInterval) async throws -> OneShotProcess.Result {
        guard let host = profile.host, !host.isEmpty else {
            throw HermesProbeError.probeFailed("profile has no host")
        }
        let script = makeProbeScript(hermesPath: profile.hermesPath)
        var arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
        ]
        if let port = profile.port {
            arguments += ["-p", String(port)]
        }
        if let identityFile = profile.identityFile {
            arguments += ["-i", identityFile]
        }
        let destination = profile.user.map { "\($0)@\(host)" } ?? host
        arguments += ["--", destination, "sh", "-lc", SSHTransport.shellQuote(script)]

        do {
            let result = try await OneShotProcess.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: arguments,
                timeout: timeout
            )
            if result.exitCode != 0 && result.stdout.isEmpty {
                // Classify SSH-level failures (auth, host key) separately from
                // hermes-binary-missing so the UI can render the right message.
                let classified = SSHTransport.classifyStderr(result.stderr)
                if case .other = classified {
                    return result
                }
                throw HermesProbeError.transportFailed(classified)
            }
            return result
        } catch let failure as OneShotProcess.Failure {
            throw HermesProbeError.probeFailed(String(describing: failure))
        }
    }

    private static func makeProbeScript(hermesPath: String) -> String {
        // `command -v` prints the resolved path; `<bin> --version` prints e.g.
        // "hermes 0.4.2". Output lands on stdout in that order, separated by a
        // newline. `set -e` keeps us from reporting a parseable version when
        // the binary wasn't found.
        let quoted = SSHTransport.shellQuote(hermesPath)
        return "set -e; command -v \(quoted); \(quoted) --version"
    }
}
#endif

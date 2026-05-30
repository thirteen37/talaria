import Foundation
import NIOCore

/// Cross-platform Hermes admin runner over NIO-SSH. Mirrors the system-ssh
/// `RemoteHermesAdminRunner` (macOS-only) but drives the remote command through
/// ``NIOSSHCommandRunner``, so iPad/iOS reach the same Tools/Doctor/Profiles
/// surfaces macOS gets. The wrapped remote command line is built by the shared
/// ``buildHermesAdminRemoteCommand(profile:command:)`` — the single source of
/// truth both transports use, so they stay byte-identical.
public struct NIOSSHHermesAdminRunner: HermesAdminRunning {
    private let profile: ServerProfile
    private let runner: RemoteCommandRunning
    private let timeout: TimeAmount

    /// Production init: mirrors ``NIOSSHCommandRunner``'s init and constructs
    /// one to run each command over a fresh authenticated channel.
    public init(
        profile: ServerProfile,
        credentialProvider: SSHCredentialProvider,
        hostKeyStore: HostKeyStore,
        hostKeyConfirmer: HostKeyConfirmer? = nil,
        passphrase: String? = nil,
        group: EventLoopGroup = NIOSSHTransport.sharedGroup,
        timeout: TimeAmount = .seconds(30)
    ) {
        self.profile = profile
        self.runner = NIOSSHCommandRunner(
            profile: profile,
            credentialProvider: credentialProvider,
            hostKeyStore: hostKeyStore,
            hostKeyConfirmer: hostKeyConfirmer,
            passphrase: passphrase,
            group: group
        )
        self.timeout = timeout
    }

    /// Seam/test init: injects a ``RemoteCommandRunning`` so command
    /// construction can be verified without a live connection.
    public init(profile: ServerProfile, runner: RemoteCommandRunning, timeout: TimeAmount = .seconds(30)) {
        self.profile = profile
        self.runner = runner
        self.timeout = timeout
    }

    public func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult {
        guard profile.kind == .ssh, !(profile.host ?? "").isEmpty else {
            return HermesAdminResult(exitCode: 1, stdout: "", stderr: "profile is not an SSH profile")
        }
        let remoteCommand = buildHermesAdminRemoteCommand(profile: profile, command: command)
        let result = try await runner.run(command: remoteCommand, timeout: timeout)
        return HermesAdminResult(
            exitCode: Int32(result.exitCode),
            stdout: result.stdout,
            stderr: result.stderr
        )
    }

    // runStream(_:) intentionally uses the `HermesAdminRunning` protocol default
    // (drains the captured output once the child exits, then synthesises line
    // events). It loses stdout/stderr interleaving.
    // TODO: add a live-streaming child handler (model on `DashboardExecHandler`)
    // so Tools/Doctor output streams incrementally instead of arriving at exit.
}

import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Outcome of a one-shot remote command run over NIO-SSH.
public struct RemoteCommandResult: Sendable {
    public var exitCode: Int
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs a single remote shell command and returns its captured result.
/// The iOS snapshot path uses this to drive `sqlite3 .backup` and the
/// `rm -f` cleanup that macOS runs via `/usr/bin/ssh`.
public protocol RemoteCommandRunning: Sendable {
    func run(command: String, timeout: TimeAmount) async throws -> RemoteCommandResult
}

extension RemoteCommandRunning {
    public func run(command: String) async throws -> RemoteCommandResult {
        try await run(command: command, timeout: .seconds(30))
    }
}

/// Builds the SSH client configuration shared by every NIO-SSH consumer
/// (the ACP transport, the snapshot `cat` transfer, and the command
/// runner). Centralizing credential resolution + the auth/host-key
/// delegates here keeps the security-critical wiring from drifting between
/// call sites.
enum NIOSSHConnectionFactory {
    /// Resolves credentials and connects a fresh authenticated SSH channel.
    /// Throws a typed ``SSHTransportError`` on auth/host-key/connect failure
    /// (already routed through ``NIOSSHTransport/mapConnectError``).
    static func connect(
        profile: ServerProfile,
        credentialProvider: SSHCredentialProvider,
        hostKeyStore: HostKeyStore,
        hostKeyConfirmer: HostKeyConfirmer?,
        passphrase: String?,
        group: EventLoopGroup
    ) async throws -> Channel {
        guard let host = profile.host, !host.isEmpty else {
            throw SSHTransportError.other("profile is not an SSH profile")
        }
        let port = profile.port ?? 22
        let user = profile.user ?? NSUserName()

        let privateKey = try credentialProvider.privateKey(for: profile, passphrase: passphrase)
        let password = try credentialProvider.password(for: profile)
        if privateKey == nil, password == nil {
            throw SSHTransportError.authFailed("profile has no identity file or password configured")
        }
        let authDelegate = NIOSSHAuthDelegate(username: user, privateKey: privateKey, password: password)
        let hostKeyDelegate = NIOSSHHostKeyVerifier(store: hostKeyStore, host: host, port: port, confirmUnknown: hostKeyConfirmer)

        let bootstrap = ClientBootstrap(group: group)
            // Match the ACP transport's connect bound so a stalled SYN
            // doesn't pin the UI for ~75s on macOS's default TCP backoff.
            .connectTimeout(.seconds(15))
            // Build the (non-Sendable) `SSHClientConfiguration` and install the
            // handler on the event loop so neither crosses the `@Sendable`
            // initializer boundary; only the Sendable delegates are captured.
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(
                            role: .client(SSHClientConfiguration(
                                userAuthDelegate: authDelegate,
                                serverAuthDelegate: hostKeyDelegate
                            )),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                    )
                }
            }

        do {
            return try await bootstrap.connect(host: host, port: port).get()
        } catch {
            throw NIOSSHTransport.mapConnectError(error, host: host, port: port)
        }
    }
}

/// Cross-platform remote command runner over a fresh NIO-SSH connection.
/// One connection per `run` — same single-shot rationale as
/// ``NIOSSHCatTransfer`` (no pooling in v1).
public struct NIOSSHCommandRunner: RemoteCommandRunning {
    private let profile: ServerProfile
    private let credentialProvider: SSHCredentialProvider
    private let hostKeyStore: HostKeyStore
    private let hostKeyConfirmer: HostKeyConfirmer?
    private let passphrase: String?
    private let group: EventLoopGroup

    public init(
        profile: ServerProfile,
        credentialProvider: SSHCredentialProvider,
        hostKeyStore: HostKeyStore,
        hostKeyConfirmer: HostKeyConfirmer? = nil,
        passphrase: String? = nil,
        group: EventLoopGroup = NIOSSHTransport.sharedGroup
    ) {
        self.profile = profile
        self.credentialProvider = credentialProvider
        self.hostKeyStore = hostKeyStore
        self.hostKeyConfirmer = hostKeyConfirmer
        self.passphrase = passphrase
        self.group = group
    }

    public func run(command: String, timeout: TimeAmount = .seconds(30)) async throws -> RemoteCommandResult {
        let connection = try await NIOSSHConnectionFactory.connect(
            profile: profile,
            credentialProvider: credentialProvider,
            hostKeyStore: hostKeyStore,
            hostKeyConfirmer: hostKeyConfirmer,
            passphrase: passphrase,
            group: group
        )
        do {
            let result = try await runOnConnection(connection: connection, command: command, timeout: timeout)
            _ = try? await connection.close().get()
            return result
        } catch {
            _ = try? await connection.close().get()
            throw error
        }
    }

    private func runOnConnection(connection: Channel, command: String, timeout: TimeAmount) async throws -> RemoteCommandResult {
        let promise = connection.eventLoop.makePromise(of: CommandResultBox.self)

        // Resolve the (non-Sendable, library) `NIOSSHHandler` and open the
        // session child channel entirely on the event loop, so it never
        // crosses an async boundary. The command handler is installed inside
        // the on-loop initializer.
        let childChannel = try await connection.eventLoop.flatSubmit { () -> EventLoopFuture<Channel> in
            let childPromise = connection.eventLoop.makePromise(of: Channel.self)
            do {
                let sshHandler = try connection.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                sshHandler.createChannel(childPromise, channelType: .session) { childChannel, _ in
                    childChannel.eventLoop.makeCompletedFuture {
                        try childChannel.pipeline.syncOperations.addHandler(
                            NIOSSHCommandHandler(command: command, complete: promise)
                        )
                    }
                }
            } catch {
                childPromise.fail(error)
            }
            return childPromise.futureResult
        }.get()

        let timer = connection.eventLoop.scheduleTask(in: timeout) {
            // On the event loop: read the handler back from the pipeline rather
            // than capturing it, then mark the timeout and tear the channel down.
            let handler = try? childChannel.pipeline.syncOperations.handler(type: NIOSSHCommandHandler.self)
            handler?.markTimedOut()
            childChannel.close(promise: nil)
        }
        promise.futureResult.whenComplete { _ in timer.cancel() }

        let box = try await promise.futureResult.get()
        if box.timedOut {
            throw SSHTransportError.commandTimeout("remote command exceeded \(timeout)")
        }
        if let error = box.error {
            throw SSHTransportError.other(error.localizedDescription)
        }
        return RemoteCommandResult(exitCode: box.exitCode, stdout: box.stdout, stderr: box.stderr)
    }

    struct CommandResultBox: @unchecked Sendable {
        var exitCode: Int = 0
        var stdout: String = ""
        var stderr: String = ""
        var error: Error?
        var timedOut: Bool = false
    }
}

/// Child-channel handler that issues a single `exec` and accumulates the
/// (expected-small) stdout/stderr in memory, capturing the exit code and
/// fulfilling `complete` on channel close. Used for control commands like
/// `sqlite3 .backup` and `rm -f` that produce little or no output.
/// `@unchecked Sendable`: like every NIO `ChannelHandler`, all callbacks run on
/// the channel's event loop and the mutable state is only touched there. The
/// conformance lets the timeout timer hold a reference to it without tripping
/// strict-concurrency capture checks.
final class NIOSSHCommandHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = Never
    typealias OutboundOut = SSHChannelData

    private let command: String
    private var complete: EventLoopPromise<NIOSSHCommandRunner.CommandResultBox>?
    private var result = NIOSSHCommandRunner.CommandResultBox()
    private var failed = false
    private var timedOut = false

    init(command: String, complete: EventLoopPromise<NIOSSHCommandRunner.CommandResultBox>) {
        self.command = command
        self.complete = complete
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let option = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        option.assumeIsolated().whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(execRequest).assumeIsolated().whenFailure { [weak self] error in
            self?.fail(error: error)
            context.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        guard case let .byteBuffer(bytes) = envelope.data else { return }
        switch envelope.type {
        case .channel:
            result.stdout += String(decoding: bytes.readableBytesView, as: UTF8.self)
        case .stdErr:
            result.stderr += String(decoding: bytes.readableBytesView, as: UTF8.self)
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exit = event as? SSHChannelRequestEvent.ExitStatus {
            result.exitCode = exit.exitStatus
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        result.timedOut = timedOut
        complete?.succeed(result)
        complete = nil
        context.fireChannelInactive()
    }

    func markTimedOut() {
        timedOut = true
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error: error)
        context.close(promise: nil)
    }

    private func fail(error: Error) {
        guard !failed else { return }
        failed = true
        result.error = error
        complete?.succeed(result)
        complete = nil
    }
}

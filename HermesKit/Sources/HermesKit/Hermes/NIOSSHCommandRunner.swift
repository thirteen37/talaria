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

/// A connected, authenticating NIO-SSH channel plus a fast-fail signal for
/// auth exhaustion. Open your first child channel via
/// ``NIOSSHConnectionFactory/openChannel(on:type:initializer:)`` (or race
/// ``authExhausted`` yourself) so a fully-rejected login surfaces immediately
/// as ``SSHTransportError/authFailed(_:)`` instead of stalling until the
/// server's `LoginGraceTime` — the iOS "connection spinner never stops" bug.
struct NIOSSHConnection: Sendable {
    let channel: Channel
    /// Fails with ``SSHTransportError/authFailed(_:)`` once every credential has
    /// been offered and rejected. Succeeds (a no-op for failure observers) when
    /// the connection closes, so it never leaks on the success path.
    let authExhausted: EventLoopFuture<Void>
}

/// Resolves at most once, bridging ``NIOSSHAuthDelegate``'s exhaustion callback
/// into a future the connection-open await can race. `onExhausted` fails it with
/// a clear auth error; `resolve()` (called from connection-close cleanup)
/// succeeds it. Either call after the latch is settled is a safe no-op, so the
/// "auth rejected" and "connection closed normally" paths can both run without
/// a "promise resolved twice" crash.
final class NIOSSHAuthLatch: @unchecked Sendable {
    private let promise: EventLoopPromise<Void>
    private let lock = NSLock()
    private var settled = false
    private let message: String

    /// `message` is surfaced verbatim via ``SSHTransportError/authFailed(_:)`` on
    /// exhaustion. Don't prefix it with "Authentication failed" — that error's
    /// errorDescription already adds it, so a prefix would double up.
    init(eventLoop: EventLoop, message: String) {
        self.promise = eventLoop.makePromise(of: Void.self)
        self.message = message
    }

    var future: EventLoopFuture<Void> { promise.futureResult }

    /// Suitable as ``NIOSSHAuthDelegate``'s `onExhausted`. Strongly captures the
    /// latch so the delegate (retained by the channel pipeline for the
    /// connection's lifetime) keeps it alive; the latch holds no ref back, so
    /// there's no cycle.
    var onExhausted: @Sendable () -> Void {
        { self.failOnce() }
    }

    func resolve() {
        lock.lock(); defer { lock.unlock() }
        guard !settled else { return }
        settled = true
        promise.succeed(())
    }

    private func failOnce() {
        lock.lock(); defer { lock.unlock() }
        guard !settled else { return }
        settled = true
        promise.fail(SSHTransportError.authFailed(message))
    }
}

/// Builds the SSH client configuration shared by every NIO-SSH consumer
/// (the dashboard connection, the snapshot `cat`/upload transfer, and the
/// command runner). Centralizing credential resolution + the auth/host-key
/// delegates here keeps the security-critical wiring from drifting between
/// call sites.
enum NIOSSHConnectionFactory {
    /// Resolves credentials and connects a fresh authenticating SSH channel.
    /// Throws a typed ``SSHTransportError`` on auth/host-key/connect failure
    /// (already routed through ``NIOSSHConnectError/map(_:host:port:)``). The returned
    /// ``NIOSSHConnection`` carries an auth-exhaustion latch so the caller's
    /// first child-channel open fails fast on a rejected login.
    static func connect(
        profile: ServerProfile,
        credentialProvider: SSHCredentialProvider,
        hostKeyStore: HostKeyStore,
        hostKeyConfirmer: HostKeyConfirmer?,
        passphrase: String?,
        group: EventLoopGroup
    ) async throws -> NIOSSHConnection {
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
        // Surface auth exhaustion (all credentials offered + rejected) as a
        // fast, clear error. Without this the child-channel open below stalls:
        // NIOSSH stops offering once we're out of credentials, but the server
        // holds the connection open until its LoginGraceTime, so the await never
        // returns and the UI spinner spins forever.
        // Name *every* credential that was offered so a user with both a key and
        // a password set knows to re-check both, not just the key.
        let authFailureMessage = NIOSSHAuthDelegate.authRejectedMessage(
            hasKey: privateKey != nil,
            hasPassword: password != nil
        )
        let authLatch = NIOSSHAuthLatch(eventLoop: group.next(), message: authFailureMessage)
        let authDelegate = NIOSSHAuthDelegate(
            username: user,
            privateKey: privateKey,
            password: password,
            onExhausted: authLatch.onExhausted
        )
        let hostKeyDelegate = NIOSSHHostKeyVerifier(store: hostKeyStore, host: host, port: port, confirmUnknown: hostKeyConfirmer)

        let bootstrap = ClientBootstrap(group: group)
            // Match the dashboard connection's connect bound so a stalled SYN
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

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            // Auth runs after TCP connect, so exhaustion can't have fired yet;
            // settle the latch so its promise doesn't leak.
            authLatch.resolve()
            throw NIOSSHConnectError.map(error, host: host, port: port)
        }
        // Settle the latch when the connection ends so it never leaks on the
        // success path; a real auth exhaustion fails it first (resolve no-ops).
        channel.closeFuture.whenComplete { _ in authLatch.resolve() }
        return NIOSSHConnection(channel: channel, authExhausted: authLatch.future)
    }

    /// Opens a child channel on `connection`, failing fast with the auth error
    /// if credentials are exhausted before the channel opens. `initializer`
    /// builds the child's handler(s) on the child's event loop.
    static func openChannel(
        on connection: NIOSSHConnection,
        type: SSHChannelType = .session,
        initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        let eventLoop = connection.channel.eventLoop
        let childPromise = eventLoop.makePromise(of: Channel.self)
        // Resolve the (non-Sendable, library) `NIOSSHHandler` and open the child
        // entirely on the event loop, so it never crosses an async boundary.
        eventLoop.execute {
            do {
                let sshHandler = try connection.channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                sshHandler.createChannel(childPromise, channelType: type) { child, _ in
                    initializer(child)
                }
            } catch {
                childPromise.fail(error)
            }
        }
        return try await raceAuthExhaustion(
            childPromise.futureResult,
            authExhausted: connection.authExhausted,
            on: eventLoop
        ).get()
    }

    /// Returns a future that settles with whichever happens first: `open`
    /// completing, or `authExhausted` failing. Resolves exactly once even when
    /// both fire — on a rejected login the latch fails *and* the queued child
    /// open then fails as the connection tears down, so the guard prevents a
    /// "promise resolved twice" crash.
    static func raceAuthExhaustion(
        _ open: EventLoopFuture<Channel>,
        authExhausted: EventLoopFuture<Void>,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Channel> {
        let result = eventLoop.makePromise(of: Channel.self)
        let once = ResolveOnce()
        open.whenComplete { outcome in
            guard once.claim() else { return }
            result.completeWith(outcome)
        }
        authExhausted.whenFailure { error in
            guard once.claim() else { return }
            result.fail(error)
        }
        return result.futureResult
    }
}

/// First-caller-wins guard so a raced promise resolves exactly once.
final class ResolveOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
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
        group: EventLoopGroup = SSHEventLoopGroup.shared
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
            _ = try? await connection.channel.close().get()
            return result
        } catch {
            _ = try? await connection.channel.close().get()
            throw error
        }
    }

    private func runOnConnection(connection: NIOSSHConnection, command: String, timeout: TimeAmount) async throws -> RemoteCommandResult {
        let eventLoop = connection.channel.eventLoop
        let promise = eventLoop.makePromise(of: CommandResultBox.self)

        // Open the session child channel, failing fast if auth was rejected
        // rather than stalling until the server's LoginGraceTime.
        let childChannel = try await NIOSSHConnectionFactory.openChannel(on: connection) { childChannel in
            childChannel.eventLoop.makeCompletedFuture {
                try childChannel.pipeline.syncOperations.addHandler(
                    NIOSSHCommandHandler(command: command, complete: promise)
                )
            }
        }

        let timer = eventLoop.scheduleTask(in: timeout) {
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

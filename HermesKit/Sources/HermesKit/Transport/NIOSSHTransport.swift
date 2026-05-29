import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Pure-Swift SSH transport. Used as an opt-in alternative to
/// ``SSHTransport`` on macOS and as the **only** transport on iOS (where
/// `/usr/bin/ssh`, `Process`, ssh-agent and `~/.ssh/config` don't exist).
///
/// Lifecycle:
/// 1. ``init(...)`` resolves the identity material synchronously via
///    ``SSHCredentialProvider``. Resolution failures (encrypted key without
///    passphrase, unreadable file) surface here as
///    ``SSHTransportError/needsPassphrase(keyPath:)`` or `.authFailed` so the
///    host app's transport factory can catch and prompt the user.
/// 2. ``start()`` opens a TCP socket, runs the SSH handshake (which consults
///    ``HostKeyStore`` and ``SSHCredentialProvider``), creates a session
///    child channel, and issues an `exec` request for the wrapped
///    `hermes acp` command. On success, ``inbound`` and ``send(_:)`` are
///    live.
/// 3. ``send(_:)`` writes bytes to the child channel as
///    `SSHChannelData(type: .channel, data: .byteBuffer(...))`.
/// 4. ``close()`` sends channel EOF, closes the child channel, then the
///    parent TCP channel. Idempotent.
public final class NIOSSHTransport: Transport, @unchecked Sendable {
    public var inbound: AsyncThrowingStream<Data, Error> { inboundStream }

    private let profile: ServerProfile
    private let hostKeyStore: HostKeyStore
    private let hostKeyConfirmer: HostKeyConfirmer?
    private let privateKey: NIOSSHPrivateKey?
    private let password: String?
    private let group: EventLoopGroup

    private let inboundStream: AsyncThrowingStream<Data, Error>
    private let inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let stderrRing = NIOSSHStderrRing()

    private let lock = NSLock()
    private var connectionChannel: Channel?
    private var childChannel: Channel?
    private var started = false
    private var closed = false

    /// Process-wide event loop group. Created lazily on first transport
    /// construction and intentionally never shut down — the cost of keeping
    /// 1 ELG thread alive is negligible compared to the bookkeeping of
    /// ref-counted shutdown for a long-running app. Tests that need a
    /// per-test group can pass their own via ``init(profile:credentialProvider:hostKeyStore:passphrase:group:)``.
    public static let sharedGroup: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    public convenience init(
        profile: ServerProfile,
        credentialProvider: SSHCredentialProvider,
        hostKeyStore: HostKeyStore,
        hostKeyConfirmer: HostKeyConfirmer? = nil,
        passphrase: String? = nil,
        group: EventLoopGroup = NIOSSHTransport.sharedGroup
    ) throws {
        let privateKey = try credentialProvider.privateKey(for: profile, passphrase: passphrase)
        let password = try credentialProvider.password(for: profile)
        if privateKey == nil, password == nil {
            throw SSHTransportError.authFailed("profile has no identity file or password configured")
        }
        self.init(
            profile: profile,
            privateKey: privateKey,
            password: password,
            hostKeyStore: hostKeyStore,
            hostKeyConfirmer: hostKeyConfirmer,
            group: group
        )
    }

    init(
        profile: ServerProfile,
        privateKey: NIOSSHPrivateKey?,
        password: String? = nil,
        hostKeyStore: HostKeyStore,
        hostKeyConfirmer: HostKeyConfirmer? = nil,
        group: EventLoopGroup
    ) {
        self.profile = profile
        self.privateKey = privateKey
        self.password = password
        self.hostKeyStore = hostKeyStore
        self.hostKeyConfirmer = hostKeyConfirmer
        self.group = group

        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        self.inboundStream = AsyncThrowingStream { continuation in
            captured = continuation
        }
        self.inboundContinuation = captured!
    }

    /// Single-shot lifecycle: this transport may only be `start()`ed once.
    /// After a failed start (auth/host-key/network), throw the captured
    /// error and require the caller to construct a fresh transport via
    /// the `SessionManager.TransportFactory` retry pattern. Trying to
    /// re-`start()` the same instance would otherwise quietly succeed
    /// (early return on `started == true`) while `closed == true`,
    /// surfacing later as a confusing `TransportError.stdinClosed`.
    public func start() async throws {
        switch markStarted() {
        case .freshStart:
            break
        case .alreadyStarted:
            throw TransportError.processAlreadyStarted
        }

        guard let host = profile.host, !host.isEmpty else {
            throw SSHTransportError.other("profile has no host")
        }
        let port = profile.port ?? 22
        let user = profile.user ?? NSUserName()
        let command = buildHermesRemoteCommand(profile: profile)
        let authKind = privateKey != nil ? "key" : "password"
        HermesLog.transport.info("connect start \(user, privacy: .public)@\(host, privacy: .public):\(port) auth=\(authKind, privacy: .public)")
        HermesLog.transport.info("remote command: \(command, privacy: .public)")

        // Surface auth exhaustion (all credentials offered + rejected) as a
        // fast, clear error instead of letting NIOSSH stall until the open
        // timeout. The delegate fires `onExhausted` on the event loop; we fail
        // this promise, which the channel-open await observes below.
        let authFailure = group.next().makePromise(of: Void.self)
        // No "Authentication failed" prefix here — `SSHTransportError.authFailed`'s
        // errorDescription already adds it, so a prefix would double up.
        let authFailureMessage = "The server rejected the \(authKind). Check the username and \(authKind) for this server."
        let authDelegate = NIOSSHAuthDelegate(
            username: user,
            privateKey: privateKey,
            password: password,
            onExhausted: { authFailure.fail(SSHTransportError.authFailed(authFailureMessage)) }
        )
        let hostKeyDelegate = NIOSSHHostKeyVerifier(store: hostKeyStore, host: host, port: port, confirmUnknown: hostKeyConfirmer)
        let config = SSHClientConfiguration(
            userAuthDelegate: authDelegate,
            serverAuthDelegate: hostKeyDelegate
        )

        let bootstrap = ClientBootstrap(group: group)
            // Mirrors the system-ssh path's ~15s bound (`ConnectTimeout=5` +
            // process timeout buffer). Without this, a dropped-packet host
            // can block ~75s on macOS's default TCP backoff.
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    NIOSSHHandler(
                        role: .client(config),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    ),
                ])
            }

        let connection: Channel
        do {
            connection = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            HermesLog.transport.error("TCP/handshake failed: \(String(describing: error), privacy: .public)")
            authFailure.succeed(()) // resolve the unused promise to avoid a leak warning
            _ = await markClosed()
            throw Self.mapConnectError(error, host: host, port: port)
        }
        HermesLog.transport.info("TCP connected + SSH handshake/auth done; opening session channel")
        storeConnection(connection)

        let inboundContinuation = inboundContinuation
        let stderrRing = stderrRing
        let childPromise = connection.eventLoop.makePromise(of: Channel.self)
        // Whichever settles first wins: the session channel opening, or auth
        // exhaustion failing it. cascade forwards childPromise's outcome;
        // a later auth failure is a no-op once the channel already opened.
        let channelOpen = connection.eventLoop.makePromise(of: Channel.self)
        childPromise.futureResult.cascade(to: channelOpen)
        authFailure.futureResult.whenFailure { channelOpen.fail($0) }
        do {
            let handler = try await connection.pipeline.handler(type: NIOSSHHandler.self).get()
            handler.createChannel(childPromise, channelType: .session) { childChannel, _ in
                let dataHandler = NIOSSHChannelHandler(
                    command: command,
                    inboundContinuation: inboundContinuation,
                    stderrRing: stderrRing
                )
                return childChannel.pipeline.addHandler(dataHandler)
            }
            let child = try await channelOpen.futureResult.get()
            // Resolve the auth-failure promise so it doesn't linger once the
            // channel is up (no-op if it already failed).
            authFailure.succeed(())
            storeChild(child)
            HermesLog.transport.info("session channel open; awaiting exec ack")
            // Wait for the ExecRequest to be accepted (or for the child
            // channel to close, e.g. on auth/host-key failure during the
            // initial handshake). The handler stashes the promise; we
            // unwrap its future on the event loop.
            let ackFuture: EventLoopFuture<Void> = try await child.eventLoop.submit {
                let handler = try child.pipeline.syncOperations.handler(type: NIOSSHChannelHandler.self)
                return handler.execAckFuture(on: child.eventLoop)
            }.get()
            try await ackFuture.get()
            HermesLog.transport.info("exec accepted — transport live")
        } catch {
            HermesLog.transport.error("session/exec setup failed: \(String(describing: error), privacy: .public)")
            authFailure.succeed(()) // resolve the unused promise to avoid a leak warning
            _ = await markClosed()
            throw Self.mapConnectError(error, host: host, port: port)
        }
    }

    private enum StartOutcome {
        case freshStart
        case alreadyStarted
    }

    private func markStarted() -> StartOutcome {
        lock.lock()
        defer { lock.unlock() }
        if started { return .alreadyStarted }
        started = true
        return .freshStart
    }

    private func storeConnection(_ channel: Channel) {
        lock.lock()
        defer { lock.unlock() }
        connectionChannel = channel
    }

    private func storeChild(_ channel: Channel) {
        lock.lock()
        defer { lock.unlock() }
        childChannel = channel
    }

    public func send(_ data: Data) async throws {
        guard let child = currentChild() else {
            throw TransportError.stdinClosed
        }
        var buffer = child.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        do {
            try await child.writeAndFlush(buffer).get()
        } catch {
            throw TransportError.writeFailed(error.localizedDescription)
        }
    }

    private func currentChild() -> Channel? {
        lock.lock()
        defer { lock.unlock() }
        return closed ? nil : childChannel
    }

    public func close() async {
        await markClosed()
    }

    public func recentStderr() -> String {
        stderrRing.snapshot()
    }

    @discardableResult
    private func markClosed() async -> Bool {
        let (already, conn, child) = takeChannelsForClose()
        if already {
            return true
        }
        if let child {
            try? await child.close(mode: .all).get()
        }
        if let conn {
            try? await conn.close().get()
        }
        inboundContinuation.finish()
        return false
    }

    private func takeChannelsForClose() -> (alreadyClosed: Bool, connection: Channel?, child: Channel?) {
        lock.lock()
        defer { lock.unlock() }
        if closed { return (true, nil, nil) }
        closed = true
        let conn = connectionChannel
        let child = childChannel
        connectionChannel = nil
        childChannel = nil
        return (false, conn, child)
    }

    /// Internal so ``NIOSSHCatTransfer`` and other future NIO-side
    /// connections funnel auth / host-key / unreachable failures through
    /// the same translator. Keeps "unknown host key" on the snapshot path
    /// surfacing as `.hostKeyUnknown` rather than a generic `.ioFailed`.
    static func mapConnectError(_ error: Error, host: String, port: Int) -> Error {
        // The SSH-layer errors we raise from our own delegates pass through
        // unchanged so the host app can pattern-match on them. Everything
        // else maps into a generic ``SSHTransportError``.
        if let typed = error as? SSHTransportError {
            return typed
        }
        if let typed = error as? HostKeyStoreError {
            return SSHTransportError.other(typed.errorDescription ?? "\(typed)")
        }
        if let nio = error as? NIOSSHError {
            return SSHTransportError.authFailed(String(describing: nio))
        }
        // `ChannelError`'s NSError bridge yields a useless "operation couldn't
        // be completed (NIOCore.ChannelError error N)" string. A channel-layer
        // failure during connect means the TCP socket was refused, reset, or
        // never established — on iOS the most common cause is Local Network
        // privacy not yet granted for a LAN/self-hosted host. Render the case
        // name and a hint instead of the opaque code.
        if let channelError = error as? ChannelError {
            return SSHTransportError.hostUnreachable(
                "\(host):\(port) — connection failed (\(String(describing: channelError))). "
                + "Check the host/port is reachable. On iOS, allow Local Network access for Talaria if the server is on your LAN."
            )
        }
        let message = (error as NSError).localizedDescription
        let lowered = message.lowercased()
        if lowered.contains("connection refused")
            || lowered.contains("no route")
            || lowered.contains("network is unreachable")
            || lowered.contains("could not resolve") {
            return SSHTransportError.hostUnreachable("\(host):\(port) — \(message)")
        }
        return SSHTransportError.other(message)
    }
}

// MARK: - Child channel handler

/// Wires the SSH session child channel into the transport's `inbound`
/// stream and stderr ring buffer, and issues the initial `ExecRequest` on
/// `channelActive`.
///
/// Inbound: `SSHChannelData` of type `.channel` is unwrapped and yielded to
/// the continuation as `Data`. `.stdErr` is appended to the ring buffer.
/// `ExitStatus` events finish the inbound stream.
///
/// Outbound: `ByteBuffer`s written into the channel are wrapped as
/// `SSHChannelData(type: .channel, ...)`.
final class NIOSSHChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let stderrRing: NIOSSHStderrRing
    private var execAckPromise: EventLoopPromise<Void>?

    init(
        command: String,
        inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation,
        stderrRing: NIOSSHStderrRing
    ) {
        self.command = command
        self.inboundContinuation = inboundContinuation
        self.stderrRing = stderrRing
    }

    func handlerAdded(context: ChannelHandlerContext) {
        execAckPromise = context.eventLoop.makePromise(of: Void.self)
        // Allow the remote peer to half-close the channel without tearing
        // down our side immediately — needed so we can drain final stdout
        // after the remote `hermes acp` exits.
        let option = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        option.assumeIsolated().whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(execRequest).assumeIsolated().whenComplete { [weak self] result in
            switch result {
            case .success:
                self?.execAckPromise?.succeed(())
            case let .failure(error):
                self?.execAckPromise?.fail(error)
                context.close(promise: nil)
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        guard case let .byteBuffer(bytes) = envelope.data else { return }
        switch envelope.type {
        case .channel:
            inboundContinuation.yield(Data(bytes.readableBytesView))
        case .stdErr:
            stderrRing.append(Data(bytes.readableBytesView))
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is SSHChannelRequestEvent.ExitStatus {
            // The remote process has exited. Let the channel close
            // naturally; `channelInactive` finishes the stream.
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        inboundContinuation.finish()
        execAckPromise?.fail(ChannelError.eof)
        execAckPromise = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        inboundContinuation.finish(throwing: error)
        execAckPromise?.fail(error)
        execAckPromise = nil
        context.close(promise: nil)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let bytes = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(bytes))), promise: promise)
    }

    /// Returns the future that fires when the `ExecRequest` round-trips
    /// (or fails). Safe to call only from the channel's event loop. If the
    /// promise is already gone (channel closed), returns an already-failed
    /// future.
    func execAckFuture(on eventLoop: EventLoop) -> EventLoopFuture<Void> {
        if let promise = execAckPromise {
            return promise.futureResult
        }
        return eventLoop.makeFailedFuture(ChannelError.alreadyClosed)
    }
}

// MARK: - Stderr ring buffer

final class NIOSSHStderrRing: @unchecked Sendable {
    private let lock = NSLock()
    private let byteLimit: Int
    private var data = Data()

    init(byteLimit: Int = 64 * 1024) {
        self.byteLimit = byteLimit
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > byteLimit {
            data.removeFirst(data.count - byteLimit)
        }
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

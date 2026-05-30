import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// iOS dashboard transport: one pure-Swift SSH connection that both runs the
/// remote `hermes dashboard` process (on a long-lived `session`/`exec`
/// channel) and carries its HTTP traffic (one `direct-tcpip` channel per
/// request to `127.0.0.1:<remotePort>` on the server).
///
/// This is the NIO-SSH equivalent of what macOS gets from a single
/// `ssh -L <local>:127.0.0.1:<remote> -- host 'hermes dashboard …'`
/// invocation: that one process both execs the dashboard and forwards a port.
/// iOS has neither `/usr/bin/ssh` nor `Process`, so we reproduce both halves
/// over swift-nio-ssh.
///
/// HTTP is spoken by hand (request serialized to bytes, response read until the
/// server closes the `Connection: close` channel) rather than via NIOHTTP1
/// codecs — the dashboard surface iOS uses is a handful of small GET/DELETE
/// JSON calls, so a full codec pipeline over `SSHChannelData` would be more
/// moving parts than it's worth.
///
/// One connection serves one dashboard for the window's lifetime. The
/// ``DashboardSupervisor`` owns acquire/release; ``terminate()`` closes the
/// exec channel (SIGHUP-ing the remote dashboard) and then the connection.
public final class NIOSSHDashboardConnection: @unchecked Sendable {
    private let profile: ServerProfile
    private let credentialProvider: SSHCredentialProvider
    private let hostKeyStore: HostKeyStore
    private let hostKeyConfirmer: HostKeyConfirmer?
    private let group: EventLoopGroup
    /// Per-request ceiling for the tunneled HTTP round-trip. Without it a
    /// half-open `direct-tcpip` channel (stalled dashboard, mobile link where
    /// SSH peer death isn't detected promptly) would never deliver its
    /// response — the response is signalled by channel close — and the
    /// long-lived poll loops would hang with no error. `URLSession` (macOS
    /// path) has an equivalent default; this is the NIO equivalent.
    private let requestTimeout: TimeAmount

    private let lock = NSLock()
    private var connectionChannel: Channel?
    private var execChannel: Channel?
    private var started = false

    private let stderrStream: AsyncStream<String>
    private let stderrContinuation: AsyncStream<String>.Continuation
    private let exitStream: AsyncStream<Int32>
    private let exitContinuation: AsyncStream<Int32>.Continuation
    private let exitBox = DashboardExitCodeBox()

    public init(
        profile: ServerProfile,
        credentialProvider: SSHCredentialProvider,
        hostKeyStore: HostKeyStore,
        hostKeyConfirmer: HostKeyConfirmer? = nil,
        requestTimeout: TimeAmount = .seconds(30),
        group: EventLoopGroup = NIOSSHTransport.sharedGroup
    ) {
        self.profile = profile
        self.credentialProvider = credentialProvider
        self.hostKeyStore = hostKeyStore
        self.hostKeyConfirmer = hostKeyConfirmer
        self.requestTimeout = requestTimeout
        self.group = group

        var capturedStderr: AsyncStream<String>.Continuation?
        self.stderrStream = AsyncStream { capturedStderr = $0 }
        self.stderrContinuation = capturedStderr!
        var capturedExit: AsyncStream<Int32>.Continuation?
        self.exitStream = AsyncStream { capturedExit = $0 }
        self.exitContinuation = capturedExit!
    }

    // MARK: - Process side

    /// Connects, authenticates, and execs the dashboard command on a session
    /// channel. Returns once the channel is open and the `exec` request has
    /// been issued — like `Process.run()`, it does not wait for the server to
    /// become reachable; the supervisor polls for that.
    public func startDashboard(command: String) async throws {
        guard markStartedIfNeeded() else { return }

        let connection = try await NIOSSHConnectionFactory.connect(
            profile: profile,
            credentialProvider: credentialProvider,
            hostKeyStore: hostKeyStore,
            hostKeyConfirmer: hostKeyConfirmer,
            passphrase: nil,
            group: group
        )
        storeConnection(connection)

        let sshHandler = try await connection.pipeline.handler(type: NIOSSHHandler.self).get()
        let childPromise = connection.eventLoop.makePromise(of: Channel.self)
        let stderrContinuation = stderrContinuation
        let exitContinuation = exitContinuation
        let exitBox = exitBox
        sshHandler.createChannel(childPromise, channelType: .session) { child, _ in
            child.eventLoop.makeCompletedFuture {
                try child.pipeline.syncOperations.addHandler(
                    DashboardExecHandler(
                        command: command,
                        stderr: stderrContinuation,
                        exit: exitContinuation,
                        exitBox: exitBox
                    )
                )
            }
        }
        let child = try await childPromise.futureResult.get()
        storeExecChannel(child)
    }

    public var stderr: AsyncStream<String> { stderrStream }

    public func exitCodeIfAvailable() -> Int32? { exitBox.value }

    public func waitForExit() async -> Int32 {
        for await code in exitStream { return code }
        return exitBox.value ?? 0
    }

    public func terminate() async {
        let (conn, exec) = takeChannels()
        if let exec {
            try? await exec.close(mode: .all).get()
        }
        if let conn {
            try? await conn.close().get()
        }
        stderrContinuation.finish()
        exitContinuation.finish()
    }

    // MARK: - HTTP side

    /// Performs one HTTP request over a fresh `direct-tcpip` channel to
    /// `127.0.0.1:<targetPort>` on the server. Writes the serialized request,
    /// reads bytes until the server closes the channel (`Connection: close`),
    /// then parses the accumulated response. Used by ``NIOSSHDashboardHTTP``.
    public func httpRequest(_ request: URLRequest, targetPort: Int) async throws -> (Data, URLResponse) {
        guard let url = request.url else {
            throw SSHTransportError.other("dashboard HTTP request has no URL")
        }
        guard let connection = currentConnection() else {
            throw SSHTransportError.other("dashboard SSH connection is not open")
        }

        let bytesPromise = connection.eventLoop.makePromise(of: ByteBuffer.self)
        let childPromise = connection.eventLoop.makePromise(of: Channel.self)
        let collector = DirectTCPIPResponseCollector(promise: bytesPromise, allocator: ByteBufferAllocator())
        // `NIOSSHHandler.createChannel` opens the child channel *synchronously*
        // when the connection is already active — the steady state once the
        // dashboard is up and reachability polling reuses the live connection.
        // That synchronous path reads `self.channel`, which asserts it runs on
        // the connection's event loop. Calling `createChannel` from this async
        // executor therefore trips `assertInEventLoop`, so hop onto the loop
        // (resolving the handler there via `syncOperations`) before opening the
        // `direct-tcpip` channel.
        connection.eventLoop.execute {
            do {
                let direct = SSHChannelType.DirectTCPIP(
                    targetHost: "127.0.0.1",
                    targetPort: targetPort,
                    originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                )
                let sshHandler = try connection.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                sshHandler.createChannel(childPromise, channelType: .directTCPIP(direct)) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(collector)
                    }
                }
            } catch {
                childPromise.fail(error)
            }
        }
        let child = try await childPromise.futureResult.get()

        // Arm a timeout: the response only arrives on channel close, so a
        // half-open channel would otherwise hang forever. On expiry mark the
        // collector timed-out and close the channel — `channelInactive` then
        // fails the promise (a single completion point, no double-resolve).
        let timeoutTask = connection.eventLoop.scheduleTask(in: requestTimeout) { [weak child, weak collector] in
            collector?.markTimedOut()
            child?.close(promise: nil)
        }
        bytesPromise.futureResult.whenComplete { _ in timeoutTask.cancel() }

        do {
            let requestBytes = DashboardHTTPWire.serializeRequest(request, url: url, targetPort: targetPort)
            var buffer = child.allocator.buffer(capacity: requestBytes.count)
            buffer.writeBytes(requestBytes)
            // The SSH child channel speaks `SSHChannelData`; write the raw HTTP
            // bytes wrapped as a `.channel` (stdout-equivalent) payload.
            try await child.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).get()
            let responseBuffer = try await bytesPromise.futureResult.get()
            _ = try? await child.close(mode: .all).get()
            let parsed = try DashboardHTTPWire.parseResponse(Data(responseBuffer.readableBytesView))
            let response = HTTPURLResponse(
                url: url,
                statusCode: parsed.status,
                httpVersion: "HTTP/1.1",
                headerFields: parsed.headers
            ) ?? HTTPURLResponse()
            return (parsed.body, response)
        } catch {
            _ = try? await child.close(mode: .all).get()
            throw error
        }
    }

    // MARK: - Locked channel state

    private func markStartedIfNeeded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if started { return false }
        started = true
        return true
    }

    private func storeConnection(_ channel: Channel) {
        lock.lock(); defer { lock.unlock() }
        connectionChannel = channel
    }

    private func storeExecChannel(_ channel: Channel) {
        lock.lock(); defer { lock.unlock() }
        execChannel = channel
    }

    private func currentConnection() -> Channel? {
        lock.lock(); defer { lock.unlock() }
        return connectionChannel
    }

    private func takeChannels() -> (connection: Channel?, exec: Channel?) {
        lock.lock(); defer { lock.unlock() }
        let conn = connectionChannel
        let exec = execChannel
        connectionChannel = nil
        execChannel = nil
        return (conn, exec)
    }
}

// MARK: - HTTP/1.1 wire format

/// Minimal HTTP/1.1 request serialization + response parsing for the
/// dashboard tunnel. Pure (no NIO types) so it's unit-testable in isolation.
enum DashboardHTTPWire {
    enum WireError: Error, Equatable {
        case malformedStatusLine
        case missingHeaderTerminator
    }

    /// Serializes an origin-form HTTP/1.1 request. Adds `Host` and
    /// `Connection: close` (one request per channel) plus `Content-Length`
    /// for a body, then the caller's headers (e.g. the session token).
    static func serializeRequest(_ request: URLRequest, url: URL, targetPort: Int) -> Data {
        let method = request.httpMethod ?? "GET"
        var lines = "\(method) \(requestURI(from: url)) HTTP/1.1\r\n"
        lines += "Host: 127.0.0.1:\(targetPort)\r\n"
        lines += "Connection: close\r\n"
        if let body = request.httpBody {
            lines += "Content-Length: \(body.count)\r\n"
        }
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            lines += "\(name): \(value)\r\n"
        }
        lines += "\r\n"
        var data = Data(lines.utf8)
        if let body = request.httpBody {
            data.append(body)
        }
        return data
    }

    /// Parses a complete HTTP/1.1 response (full byte blob, since we read until
    /// the server closes the connection). Splits on the header terminator and
    /// returns the status code, headers, and the remaining body bytes verbatim.
    static func parseResponse(_ data: Data) throws -> (status: Int, headers: [String: String], body: Data) {
        let terminator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: terminator) else {
            throw WireError.missingHeaderTerminator
        }
        let headerData = data.subdata(in: data.startIndex..<range.lowerBound)
        let body = data.subdata(in: range.upperBound..<data.endIndex)
        let headerText = String(decoding: headerData, as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw WireError.malformedStatusLine }

        let statusLine = lines.removeFirst()
        // "HTTP/1.1 200 OK" → 200
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard statusParts.count >= 2, let code = Int(statusParts[1]) else {
            throw WireError.malformedStatusLine
        }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return (code, headers, body)
    }

    /// Origin-form request target (`/path?query`) from an absolute URL. Falls
    /// back to "/" for an empty path so the server always sees a valid target.
    static func requestURI(from url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.path.isEmpty ? "/" : url.path
        }
        var uri = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery, !query.isEmpty {
            uri += "?" + query
        }
        return uri
    }
}

// MARK: - Channel handlers

/// Long-lived `exec` handler for the remote `hermes dashboard`. Issues the
/// command on activation, streams stderr to the supervisor (which scrapes it
/// for the missing-`[web]`-extra hint), and records the exit code so the
/// supervisor's reachability loop can detect an early crash.
final class DashboardExecHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let stderr: AsyncStream<String>.Continuation
    private let exit: AsyncStream<Int32>.Continuation
    private let exitBox: DashboardExitCodeBox

    init(
        command: String,
        stderr: AsyncStream<String>.Continuation,
        exit: AsyncStream<Int32>.Continuation,
        exitBox: DashboardExitCodeBox
    ) {
        self.command = command
        self.stderr = stderr
        self.exit = exit
        self.exitBox = exitBox
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let option = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        option.assumeIsolated().whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(execRequest).assumeIsolated().whenFailure { error in
            context.fireErrorCaught(error)
            context.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        guard case let .byteBuffer(bytes) = envelope.data else { return }
        if envelope.type == .stdErr {
            stderr.yield(String(decoding: bytes.readableBytesView, as: UTF8.self))
        }
        // stdout (.channel) is uvicorn boot noise — discarded, like the macOS
        // launcher routes it to /dev/null.
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exitStatus = event as? SSHChannelRequestEvent.ExitStatus {
            exitBox.publish(Int32(exitStatus.exitStatus))
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        let code = exitBox.value ?? 143
        exitBox.publish(code)
        exit.yield(code)
        exit.finish()
        stderr.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// Accumulates the raw bytes of a `direct-tcpip` channel (unwrapping the
/// `SSHChannelData` envelopes) and fulfills `promise` with the full buffer when
/// the server closes the connection. We rely on `Connection: close`, so close
/// is the end-of-response signal.
///
/// `@unchecked Sendable` because it is event-loop-confined: after `init` (the
/// only off-loop touch, a safe handoff) every access — the channel callbacks
/// and `markTimedOut()` — happens on the connection's single shared event loop.
/// The marker lets `httpRequest` hand the collector to `eventLoop.execute`
/// (a `@Sendable` closure) without tripping strict-concurrency capture checks
/// on Swift 6 toolchains that lack region-based isolation analysis.
final class DirectTCPIPResponseCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private var promise: EventLoopPromise<ByteBuffer>?
    private var accumulator: ByteBuffer
    private var timedOut = false

    init(promise: EventLoopPromise<ByteBuffer>, allocator: ByteBufferAllocator) {
        self.promise = promise
        self.accumulator = allocator.buffer(capacity: 1024)
    }

    /// Flags that the request deadline fired; `channelInactive` (triggered by
    /// the timeout's channel close) then fails the promise instead of
    /// succeeding with a partial/empty buffer.
    func markTimedOut() {
        timedOut = true
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        guard envelope.type == .channel, case var .byteBuffer(bytes) = envelope.data else { return }
        accumulator.writeBuffer(&bytes)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if timedOut {
            promise?.fail(SSHTransportError.commandTimeout("dashboard HTTP request timed out"))
        } else {
            promise?.succeed(accumulator)
        }
        promise = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise?.fail(error)
        promise = nil
        context.close(promise: nil)
    }
}

/// Thread-safe exit-code holder shared between the exec handler (writer) and
/// the supervisor's reachability poll (reader).
final class DashboardExitCodeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int32?

    var value: Int32? {
        lock.lock(); defer { lock.unlock() }
        return code
    }

    func publish(_ newValue: Int32) {
        lock.lock(); defer { lock.unlock() }
        if code == nil { code = newValue }
    }
}

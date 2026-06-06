import Foundation
import NIOCore
import NIOSSH
import NIOWebSocket

/// ``GatewayWebSocket`` for iOS: an RFC 6455 WebSocket layered over a persistent
/// `direct-tcpip` channel on the shared ``NIOSSHDashboardConnection``. macOS uses
/// `URLSessionGatewayWebSocket` over the real `ssh -L` loopback socket; iOS has
/// no local socket, so we hand-roll the HTTP/1.1 Upgrade handshake (see
/// ``GatewayWebSocketHandshake``) and then run swift-nio's frame codecs over the
/// SSH channel's `SSHChannelData` envelopes.
///
/// > Note: The handshake math and the frame codecs are unit-tested / library
/// > code, but the end-to-end SSH integration requires a live remote host and is
/// > verified manually (see `docs/gateway-chat.md`).
public final class NIOSSHGatewayWebSocket: GatewayWebSocket, @unchecked Sendable {
    public nonisolated let messages: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let channelBox = NIOLoopBoundChannelBox()

    private init(
        messages: AsyncThrowingStream<Data, Error>,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) {
        self.messages = messages
        self.continuation = continuation
    }

    /// Opens the tunnel: a `direct-tcpip` channel to `127.0.0.1:<remotePort>`,
    /// the HTTP/1.1 Upgrade handshake, then the WebSocket frame pipeline.
    /// Returns once the 101 response has validated, or throws on failure.
    public static func connect(
        connection: NIOSSHDashboardConnection,
        remotePort: Int,
        path: String = "/api/ws",
        credential: GatewayCredential
    ) async throws -> NIOSSHGatewayWebSocket {
        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        let stream = AsyncThrowingStream<Data, Error> { captured = $0 }
        let socket = NIOSSHGatewayWebSocket(messages: stream, continuation: captured!)

        let key = GatewayWebSocketHandshake.makeKey()
        let host = "127.0.0.1:\(remotePort)"
        let fullPath: String = {
            let value = credential.value
            guard !value.isEmpty else { return path }
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(path)?\(credential.queryName)=\(encoded)"
        }()
        let signal = HandshakeSignal()
        let continuation = socket.continuation

        let channel = try await connection.openDirectTCPIPChannel(targetPort: remotePort) { child in
            child.eventLoop.makeCompletedFuture {
                try child.pipeline.syncOperations.addHandlers([
                    SSHChannelDataCodec(),
                    GatewayWebSocketUpgradeHandler(
                        requestBytes: GatewayWebSocketHandshake.requestBytes(path: fullPath, host: host, key: key),
                        key: key,
                        signal: signal,
                        sink: GatewayWebSocketSink(continuation: continuation)
                    )
                ])
            }
        }
        socket.channelBox.set(channel)

        do {
            try await signal.wait()
        } catch {
            try? await channel.close().get()
            continuation.finish(throwing: error)
            throw error
        }
        return socket
    }

    public func send(_ data: Data) async throws {
        guard let channel = channelBox.get() else { throw GatewayWebSocketError.notConnected }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        // Client → server frames MUST be masked (RFC 6455 §5.3).
        let frame = WebSocketFrame(fin: true, opcode: .text, maskKey: Self.makeMaskKey(), data: buffer)
        do {
            try await channel.writeAndFlush(frame).get()
        } catch {
            throw GatewayWebSocketError.sendFailed(error.localizedDescription)
        }
    }

    public func close() async {
        guard let channel = channelBox.take() else {
            continuation.finish()
            return
        }
        try? await channel.close().get()
        continuation.finish()
    }

    static func makeMaskKey() -> WebSocketMaskingKey {
        WebSocketMaskingKey((0..<4).map { _ in UInt8.random(in: .min ... .max) })!
    }
}

// MARK: - Handshake signal

/// One-shot async signal bridging the NIO handshake handler back to `connect()`.
final class HandshakeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var settled: Result<Void, Error>?

    func wait() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let settled {
                lock.unlock()
                cont.resume(with: settled)
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }

    func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        if let cont = continuation {
            continuation = nil
            lock.unlock()
            cont.resume(with: result)
        } else if settled == nil {
            settled = result
            lock.unlock()
        } else {
            lock.unlock()
        }
    }
}

/// Holds the WebSocket `Channel` for off-loop access. Channel methods are
/// thread-safe (they hop to the loop internally), so a plain locked box suffices.
final class NIOLoopBoundChannelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: Channel?
    func set(_ channel: Channel) { lock.lock(); self.channel = channel; lock.unlock() }
    func get() -> Channel? { lock.lock(); defer { lock.unlock() }; return channel }
    func take() -> Channel? { lock.lock(); defer { lock.unlock() }; let c = channel; channel = nil; return c }
}

// MARK: - Pipeline handlers

/// Bridges the SSH child channel's `SSHChannelData` envelopes to/from plain
/// `ByteBuffer`s, so HTTP/WebSocket codecs above it work as on a TCP channel.
final class SSHChannelDataCodec: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func handlerAdded(context: ChannelHandlerContext) {
        // The tunnel is bidirectional + long-lived; allow the peer to half-close.
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .assumeIsolated().whenFailure { context.fireErrorCaught($0) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        guard envelope.type == .channel, case let .byteBuffer(buffer) = envelope.data else { return }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

/// Sends the HTTP/1.1 Upgrade request, buffers the response until the header
/// block is complete, validates the 101, then swaps itself out for the
/// WebSocket frame codecs + sink (replaying any frame bytes the server
/// pipelined after the handshake).
final class GatewayWebSocketUpgradeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let requestBytes: Data
    private let key: String
    private let signal: HandshakeSignal
    private let sink: GatewayWebSocketSink
    private var accumulated = Data()
    private var upgraded = false

    init(requestBytes: Data, key: String, signal: HandshakeSignal, sink: GatewayWebSocketSink) {
        self.requestBytes = requestBytes
        self.key = key
        self.signal = signal
        self.sink = sink
    }

    func channelActive(context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: requestBytes.count)
        buffer.writeBytes(requestBytes)
        // Write the raw HTTP bytes downstream (SSHChannelDataCodec wraps them).
        context.writeAndFlush(NIOAny(buffer), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if upgraded {
            context.fireChannelRead(data)
            return
        }
        var buffer = unwrapInboundIn(data)
        accumulated.append(contentsOf: buffer.readableBytesView)
        buffer.moveReaderIndex(to: buffer.writerIndex)

        guard let response = GatewayWebSocketHandshake.parseResponse(accumulated) else { return }
        guard GatewayWebSocketHandshake.isValidUpgrade(response, key: key) else {
            let error = GatewayWebSocketError.closedWithCode(response.status)
            signal.resolve(.failure(error))
            context.close(promise: nil)
            return
        }

        upgraded = true
        let leftover = accumulated.suffix(from: accumulated.index(accumulated.startIndex, offsetBy: response.headerByteCount))
        accumulated = Data()

        do {
            // Insert encoder first then decoder, both `.after(self)`, so the
            // final order is [self, decoder, encoder, sink]: inbound bytes flow
            // self → decoder → sink; outbound frames flow sink → encoder → self →
            // SSHChannelDataCodec. This handler stays as an inbound pass-through.
            try context.pipeline.syncOperations.addHandler(WebSocketFrameEncoder(), position: .after(self))
            try context.pipeline.syncOperations.addHandler(
                ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: 1 << 24)),
                position: .after(self)
            )
            try context.pipeline.syncOperations.addHandler(sink, position: .last)
        } catch {
            signal.resolve(.failure(error))
            context.close(promise: nil)
            return
        }

        signal.resolve(.success(()))

        // Replay frame bytes the server pipelined after the 101 so the decoder
        // (now downstream) sees them.
        if !leftover.isEmpty {
            var replay = context.channel.allocator.buffer(capacity: leftover.count)
            replay.writeBytes(leftover)
            context.fireChannelRead(wrapInboundOut(replay))
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        signal.resolve(.failure(error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        signal.resolve(.failure(GatewayWebSocketError.closed))
        context.fireChannelInactive()
    }
}

/// Terminal WebSocket handler: reassembles data frames into messages, answers
/// pings, and finishes the stream on close. Outbound control frames (pong) are
/// written back through the pipeline.
final class GatewayWebSocketSink: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var fragment = Data()

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text, .binary, .continuation:
            var payload = frame.unmaskedData
            if let bytes = payload.readBytes(length: payload.readableBytes) {
                fragment.append(contentsOf: bytes)
            }
            if frame.fin {
                continuation.yield(fragment)
                fragment = Data()
            }
        case .ping:
            let pong = WebSocketFrame(
                fin: true,
                opcode: .pong,
                maskKey: NIOSSHGatewayWebSocket.makeMaskKey(),
                data: frame.unmaskedData
            )
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            continuation.finish()
            context.close(promise: nil)
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(throwing: error)
        context.close(promise: nil)
    }
}

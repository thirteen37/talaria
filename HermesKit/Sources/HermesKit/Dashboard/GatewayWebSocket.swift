import Foundation

/// A bidirectional WebSocket carrying the Hermes dashboard `/api/ws` gateway
/// (JSON-RPC-2.0 frames as UTF-8 text). Abstracted so ``GatewayChatClient`` can
/// share all JSON-RPC correlation + event-mapping logic across transports:
///
/// - ``URLSessionGatewayWebSocket`` — macOS local + `ssh -L` remote, wrapping
///   `URLSessionWebSocketTask`.
/// - `NIOSSHGatewayWebSocket` — iOS, RFC 6455 over a persistent `direct-tcpip`
///   channel on the shared NIO-SSH connection (Phase 3).
///
/// Mirrors the ``Transport`` seam (`inbound` stream + `send` + `close`).
public protocol GatewayWebSocket: Sendable {
    /// Inbound frames as raw `Data` (the JSON text of each WebSocket message).
    /// Finishes (optionally throwing) when the socket closes.
    nonisolated var messages: AsyncThrowingStream<Data, Error> { get }

    /// Send one JSON frame to the gateway.
    func send(_ data: Data) async throws

    func close() async
}

public enum GatewayWebSocketError: Error, Equatable, Sendable, LocalizedError {
    case notConnected
    case closed
    /// The gateway closed with a WebSocket close code (e.g. 4401 auth failed,
    /// 4403 host-not-loopback).
    case closedWithCode(Int)
    case sendFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Gateway WebSocket is not connected."
        case .closed: return "Gateway WebSocket closed."
        case let .closedWithCode(code): return "Gateway WebSocket closed with code \(code)."
        case let .sendFailed(message): return "Gateway WebSocket send failed: \(message)"
        }
    }
}

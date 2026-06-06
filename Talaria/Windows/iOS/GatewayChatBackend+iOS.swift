import Foundation
import HermesKit

/// iOS wiring that builds a WebSocket (`/api/ws`) chat backend over the window's
/// live NIO-SSH dashboard connection (iOS has no loopback socket, so it can't
/// use `URLSessionGatewayWebSocket` like macOS). The connection + remote port +
/// session arrive via the `GatewayChatTunnel` the harness fills once the
/// dashboard is up. Platform mirror of `Windows/macOS/GatewayChatBackend+macOS.swift`.
enum GatewayChatBackend {
    /// A backend factory that opens a ``GatewayChatClient`` over the window's live
    /// NIO-SSH dashboard tunnel. Throws if the tunnel isn't up yet (the dashboard
    /// is acquired on window open, so a session opened before then errors and the
    /// user retries).
    static func makeFactory(
        tunnel: @escaping @Sendable () -> GatewayChatTunnel?
    ) -> SessionManager.ChatBackendFactory {
        {
            guard let tunnel = tunnel() else {
                throw GatewayChatError.sessionNotReady
            }
            // The WS handshake carries the token in the query string, so resolve
            // it before connecting (HTTP can lazily 401-refresh; the socket can't).
            var token = tunnel.session.tokenSnapshot()
            if token == nil {
                token = try? await tunnel.session.refresh()
            }
            let socket = try await NIOSSHGatewayWebSocket.connect(
                connection: tunnel.connection,
                remotePort: tunnel.remotePort,
                token: token
            )
            return GatewayChatClient(webSocket: socket)
        }
    }
}

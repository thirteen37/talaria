import Foundation
import HermesKit

/// iOS wiring that builds a WebSocket (`/api/ws`) chat backend over the window's
/// live NIO-SSH dashboard connection (iOS has no loopback socket, so it can't
/// use `URLSessionGatewayWebSocket` like macOS). The connection + remote port +
/// session arrive via the `GatewayChatTunnel` the harness fills once the
/// dashboard is up. Platform mirror of `Windows/macOS/GatewayChatBackend+macOS.swift`.
enum GatewayChatBackend {
    /// A backend factory that picks the WS gateway when the user opted in
    /// (`isEnabled`), the connected Hermes advertises `/api/ws`
    /// (`HermesCapability.gatewayChat`), and the dashboard tunnel is live —
    /// otherwise (or on any WS open failure) it builds the ACP backend, so chat
    /// always works.
    static func makeSelectingFactory(
        isEnabled: @escaping @Sendable () -> Bool,
        liveVersion: @escaping @Sendable () -> HermesVersion?,
        tunnel: @escaping @Sendable () -> GatewayChatTunnel?,
        capabilities: CapabilityTable = CapabilityTable(),
        acpFactory: @escaping SessionManager.ChatBackendFactory
    ) -> SessionManager.ChatBackendFactory {
        {
            let supported = liveVersion().map { capabilities.has(.gatewayChat, in: $0) } ?? false
            guard isEnabled(), supported, let tunnel = tunnel() else {
                return try await acpFactory()
            }
            do {
                // The WS handshake carries the token in the query string, so
                // resolve it before connecting (HTTP can lazily 401-refresh; the
                // socket can't).
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
            } catch {
                // Tunnel open failed — fall back so chat still works over ACP.
                return try await acpFactory()
            }
        }
    }
}

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
        tunnel: @escaping @Sendable () -> GatewayChatTunnel?,
        hermesProfileName: String
    ) -> SessionManager.ChatBackendFactory {
        {
            guard let tunnel = tunnel() else {
                throw GatewayChatError.sessionNotReady
            }
            // Prefer a single-use ticket (gated dashboards reject ?token=); fall
            // back to a freshly re-scraped session token. The handshake carries
            // the credential in the query string and can't lazily 401-refresh.
            let credential = await resolveCredential(session: tunnel.session)
            let socket = try await NIOSSHGatewayWebSocket.connect(
                connection: tunnel.connection,
                remotePort: tunnel.remotePort,
                credential: credential
            )
            return GatewayChatClient(webSocket: socket, hermesProfileName: hermesProfileName)
        }
    }

    static func resolveCredential(session: DashboardSession) async -> GatewayCredential {
        if let ticket = try? await session.client().mintWSTicket() {
            return .ticket(ticket)
        }
        let token = (try? await session.refresh()) ?? session.tokenSnapshot() ?? ""
        return .token(token)
    }
}

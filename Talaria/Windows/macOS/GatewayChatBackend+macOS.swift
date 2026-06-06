import Foundation
import HermesKit

/// macOS wiring that builds a WebSocket (`/api/ws`) chat backend on top of the
/// window's shared `hermes dashboard`. Reachable wherever the dashboard exposes a
/// real loopback socket — local and the `ssh -L` remote forward (the iOS NIO-SSH
/// path uses `NIOSSHGatewayWebSocket`). See `docs/gateway-chat.md`.
enum GatewayChatBackend {
    /// Per-session refcount on the window's dashboard plus the connection
    /// details needed to open the gateway socket.
    struct Acquired: Sendable {
        let baseURL: URL
        let credential: GatewayCredential
        let supervisor: DashboardSupervisor
    }

    /// Acquires (a refcount on) the shared dashboard for `profile` and resolves
    /// the WebSocket auth credential. `DashboardCoordinator` caches one
    /// supervisor per `(profile, hermesProfile)`, so this rides the same
    /// `hermes dashboard` the window's non-chat surfaces already use.
    @MainActor
    static func acquire(
        profile: ServerProfile,
        hermesProfileName: String
    ) async throws -> Acquired {
        let (endpoint, supervisor) = try await DashboardCoordinator.shared.acquire(
            profile: profile,
            hermesProfileName: hermesProfileName
        )
        return Acquired(
            baseURL: endpoint.baseURL,
            credential: await resolveCredential(session: endpoint.session),
            supervisor: supervisor
        )
    }

    /// Resolve the credential for the `/api/ws` upgrade. Prefer a single-use
    /// ticket (gated dashboards reject `?token=`); fall back to a freshly
    /// re-scraped session token for loopback dashboards (the token rotates when
    /// the dashboard restarts, and the handshake — unlike HTTP — can't lazily
    /// 401-refresh, so a stale snapshot would be rejected).
    static func resolveCredential(session: DashboardSession) async -> GatewayCredential {
        if let ticket = try? await session.client().mintWSTicket() {
            return .ticket(ticket)
        }
        let token = (try? await session.refresh()) ?? session.tokenSnapshot() ?? ""
        return .token(token)
    }

    /// A `ChatBackendFactory` that opens one gateway socket per session and
    /// releases the dashboard refcount when the session closes.
    static func makeFactory(
        profile: ServerProfile,
        hermesProfileName: String
    ) -> SessionManager.ChatBackendFactory {
        {
            let acquired = try await acquire(profile: profile, hermesProfileName: hermesProfileName)
            do {
                let socket = try URLSessionGatewayWebSocket(
                    dashboardBaseURL: acquired.baseURL,
                    credential: acquired.credential
                )
                return GatewayChatClient(webSocket: socket) {
                    await DashboardCoordinator.shared.release(acquired.supervisor)
                }
            } catch {
                // The onClose release only fires once the client exists; if the
                // socket init throws, release the refcount here so a failed open
                // doesn't strand `hermes dashboard` past its last consumer.
                await DashboardCoordinator.shared.release(acquired.supervisor)
                throw error
            }
        }
    }
}

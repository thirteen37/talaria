import CryptoKit
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
            HermesLog.gateway.info("using ws ticket (gated dashboard) base=\(session.baseURL.absoluteString, privacy: .public)")
            return .ticket(ticket)
        }
        // Loopback `?token=` mode. The WS handshake — unlike HTTP, which skips
        // auth on loopback — strictly compares the token to the dashboard's live
        // `_SESSION_TOKEN`, so a STALE token (from a swallowed `refresh()` error
        // falling back to a cached snapshot) is the one way a working HTTP token
        // still 403s the upgrade. Log which path we took + a one-way fingerprint
        // so a `refresh=ok` + 403 (→ host/origin gate, not token) is
        // distinguishable from `refresh=failed→stale` + 403 (→ token_mismatch).
        let token: String
        let source: String
        do {
            token = try await session.refresh()
            source = "refresh"
        } catch {
            let snapshot = session.tokenSnapshot()
            token = snapshot ?? ""
            source = "refresh-FAILED→\(snapshot != nil ? "snapshot" : "empty") err=\(String(describing: error))"
        }
        HermesLog.gateway.info(
            "using session token (loopback) base=\(session.baseURL.absoluteString, privacy: .public) source=\(source, privacy: .public) tokenPresent=\(!token.isEmpty, privacy: .public) fp=\(tokenFingerprint(token), privacy: .public)"
        )
        return .token(token)
    }

    /// One-way fingerprint (truncated SHA-256) of a credential, safe to log:
    /// lets us tell whether the token the app sent matches the dashboard's live
    /// `_SESSION_TOKEN` (compare against the SPA scrape) without ever writing the
    /// secret itself to the log. `<empty>` for an absent token.
    static func tokenFingerprint(_ token: String) -> String {
        guard !token.isEmpty else { return "<empty>" }
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
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
                return GatewayChatClient(webSocket: socket, hermesProfileName: hermesProfileName) {
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

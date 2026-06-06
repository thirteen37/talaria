import Foundation
import HermesKit

/// macOS wiring that builds a WebSocket (`/api/ws`) chat backend on top of the
/// window's shared `hermes dashboard`, as an alternative to the ACP subprocess
/// transport. Reachable wherever the dashboard exposes a real loopback socket —
/// local and the `ssh -L` remote forward — i.e. everything except the iOS
/// NIO-SSH path (which gets `NIOSSHGatewayWebSocket` in Phase 3).
///
/// Selection is behind ``ServerWindowHarness/preferGatewayChat()`` (default
/// off), so the shipping app stays on ACP until the WebSocket path is verified
/// end-to-end. See `docs/gateway-chat.md`.
enum GatewayChatBackend {
    /// Per-session refcount on the window's dashboard plus the connection
    /// details needed to open the gateway socket.
    struct Acquired: Sendable {
        let baseURL: URL
        let token: String?
        let supervisor: DashboardSupervisor
    }

    /// Acquires (a refcount on) the shared dashboard for `profile`, scrapes the
    /// session token if needed, and returns the WebSocket connection inputs.
    /// `DashboardCoordinator` caches one supervisor per `(profile, hermesProfile)`,
    /// so this rides the same `hermes dashboard` the window's non-chat surfaces
    /// already use rather than spawning a second one.
    @MainActor
    static func acquire(
        profile: ServerProfile,
        hermesProfileName: String
    ) async throws -> Acquired {
        let (endpoint, supervisor) = try await DashboardCoordinator.shared.acquire(
            profile: profile,
            hermesProfileName: hermesProfileName
        )
        // The WS handshake carries the token in the query string, so it must be
        // resolved before connecting (HTTP can lazily 401-refresh; the socket
        // can't).
        var token = endpoint.session.tokenSnapshot()
        if token == nil {
            token = try? await endpoint.session.refresh()
        }
        return Acquired(baseURL: endpoint.baseURL, token: token, supervisor: supervisor)
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
                    token: acquired.token
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

    /// Builds a backend factory that picks the WS gateway when the user opted in
    /// (`isEnabled`) **and** the connected Hermes advertises `/api/ws`
    /// (`HermesCapability.gatewayChat`), otherwise builds the ACP backend.
    /// The decision is made per session at open time (reading `liveVersion`), so
    /// flipping the flag against an older Hermes — or before the version is known
    /// — safely stays on ACP. A WS open that fails also falls back to ACP, so a
    /// dashboard hiccup never blocks chat.
    static func makeSelectingFactory(
        profile: ServerProfile,
        hermesProfileName: String,
        isEnabled: @escaping @Sendable () -> Bool,
        liveVersion: @escaping @Sendable () -> HermesVersion?,
        capabilities: CapabilityTable = CapabilityTable(),
        acpFactory: @escaping SessionManager.ChatBackendFactory
    ) -> SessionManager.ChatBackendFactory {
        let wsFactory = makeFactory(profile: profile, hermesProfileName: hermesProfileName)
        return {
            let supported = liveVersion().map { capabilities.has(.gatewayChat, in: $0) } ?? false
            guard isEnabled(), supported else {
                return try await acpFactory()
            }
            do {
                return try await wsFactory()
            } catch {
                // WS couldn't open (dashboard unreachable, etc.) — fall back so
                // chat still works on the ACP path.
                return try await acpFactory()
            }
        }
    }
}

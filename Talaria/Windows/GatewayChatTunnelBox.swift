import Foundation
import HermesKit

/// Everything the iOS gateway-chat factory needs to open a `/api/ws` tunnel over
/// the window's live NIO-SSH dashboard connection: the (already-started) SSH
/// connection, the remote dashboard bind port, and the session for the token.
/// iOS-only — macOS reaches the gateway over a real loopback socket via
/// `DashboardCoordinator` instead.
struct GatewayChatTunnel: Sendable {
    let connection: NIOSSHDashboardConnection
    let remotePort: Int
    let session: DashboardSession
}

/// Thread-safe holder for the iOS gateway tunnel, filled by the harness once the
/// dashboard is live (`acquireDashboard()`) and read by the chat backend factory
/// at session-open time. nil until the dashboard connects (the factory throws
/// `GatewayChatError.sessionNotReady` so the user can retry), and on macOS.
final class GatewayChatTunnelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tunnel: GatewayChatTunnel?

    func set(_ tunnel: GatewayChatTunnel?) {
        lock.lock()
        self.tunnel = tunnel
        lock.unlock()
    }

    func get() -> GatewayChatTunnel? {
        lock.lock()
        defer { lock.unlock() }
        return tunnel
    }
}

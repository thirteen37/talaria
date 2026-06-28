import Foundation
import os

/// Shared loggers for HermesKit. All use a `com.talaria.hermeskit` subsystem
/// so they surface in macOS Console.app / sysdiagnose alongside the host app's
/// `com.talaria.*` loggers (filter `subsystem:com.talaria`) — essential for
/// debugging SSH connection failures on iOS field builds with no attached Mac.
/// See `docs/viewing-logs.md`.
public enum HermesLog {
    public static let transport = Logger(subsystem: "com.talaria.hermeskit", category: "transport")
    public static let session = Logger(subsystem: "com.talaria.hermeskit", category: "session")
    public static let snapshot = Logger(subsystem: "com.talaria.hermeskit", category: "snapshot")
    /// Dashboard supervisor lifecycle: spawn command, reachability probes, and
    /// why a dashboard failed to come online. The probe/timeout detail here is
    /// what makes a "Dashboard didn't come online" failure diagnosable — the
    /// banner only carries a one-line summary; the full stderr/command land here.
    public static let dashboard = Logger(subsystem: "com.talaria.hermeskit", category: "dashboard")
    /// Live-chat WebSocket gateway (`/api/ws`): connection lifecycle, the
    /// handshake result (incl. the HTTP status the server returned on a rejected
    /// upgrade — the one detail `-1011 "bad response"` otherwise hides), and the
    /// JSON-RPC turn flow. Surfaced in macOS Console.app / sysdiagnose under
    /// the `com.talaria.hermeskit` `gateway` category.
    public static let gateway = Logger(subsystem: "com.talaria.hermeskit", category: "gateway")
}

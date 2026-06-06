import Foundation
import os

/// Shared loggers for HermesKit. All use a `com.talaria.hermeskit` subsystem
/// so the host app's in-app log console (which reads `OSLogStore` for the
/// current process) can surface them on-device — essential for debugging SSH
/// connection failures on iOS where there's no attached Xcode console.
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
    /// JSON-RPC turn flow. Surfaced in the in-app log console.
    public static let gateway = Logger(subsystem: "com.talaria.hermeskit", category: "gateway")
}

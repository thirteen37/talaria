import HermesKit

/// iOS variant: reuses the window's live NIO-SSH dashboard connection to open a
/// `direct-tcpip` channel straight to the remote Hindsight daemon's loopback
/// port — no local forward process. Returns nil for local profiles or before the
/// dashboard tunnel is up.
enum HindsightTransportSeam {
    @MainActor
    static func make(windowHarness: ServerWindowHarness) -> (any HindsightRemoteTransport)? {
        guard windowHarness.profile.kind == .ssh,
              let connection = windowHarness.chatTunnelBox?.get()?.connection
        else { return nil }
        return NIOHindsightTransport(connection: connection)
    }
}

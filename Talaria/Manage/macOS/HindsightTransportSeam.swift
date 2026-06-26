import HermesKit

/// macOS variant: reaches a remote profile's Hindsight daemon through a managed
/// `ssh -L <ephemeral>:127.0.0.1:<remotePort> -N` forward (same auth/host-key
/// trust as the dashboard), then talks to it over the local loopback with
/// `URLSession`. Returns nil for local profiles (which dial the daemon directly).
enum HindsightTransportSeam {
    @MainActor
    static func make(windowHarness: ServerWindowHarness) -> (any HindsightRemoteTransport)? {
        guard windowHarness.profile.kind == .ssh else { return nil }
        return SSHForwardHindsightTransport(profile: windowHarness.profile)
    }
}

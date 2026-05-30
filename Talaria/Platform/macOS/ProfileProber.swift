import HermesKit

/// Capability probe seam. macOS drives the system-ssh / local `HermesProbe`;
/// the iOS mirror in `Platform/iOS/` uses the `#if`-free `NIOHermesProbe`.
enum ProfileProber {
    /// `confirmer` is unused on macOS — system-ssh defers host-key trust to
    /// `~/.ssh/known_hosts` rather than our TOFU coordinator.
    static func probe(profile: ServerProfile, confirmer: HostKeyConfirmer?) async throws -> HermesProbeResult {
        try await HermesProbe.probe(profile: profile)
    }
}

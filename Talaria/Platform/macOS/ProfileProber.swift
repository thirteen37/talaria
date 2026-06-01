import HermesKit

/// Capability probe seam. macOS drives the system-ssh / local `HermesProbe`;
/// the iOS mirror in `Platform/iOS/` uses the `#if`-free `NIOHermesProbe`.
enum ProfileProber {
    /// `confirmer` is unused on macOS — system-ssh defers host-key trust to
    /// `~/.ssh/known_hosts` rather than our TOFU coordinator. `password` is
    /// accepted for call-site parity with the iOS mirror but ignored: macOS has
    /// no password auth (the system-ssh probe uses `BatchMode=yes`).
    static func probe(profile: ServerProfile, password: String = "", confirmer: HostKeyConfirmer?) async throws -> HermesProbeResult {
        try await HermesProbe.probe(profile: profile)
    }
}

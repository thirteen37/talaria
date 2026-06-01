import HermesKit

/// Capability probe seam (iOS) — mirror of `Platform/macOS/ProfileProber.swift`.
/// Drives the `#if`-free `NIOHermesProbe` over a `NIOSSHCommandRunner` wired
/// with the same `FileIdentityProvider` + shared pinned host-key store the
/// window uses, so a host trusted by the chat transport probes silently. A
/// first probe of a brand-new host surfaces the trust prompt via `confirmer`.
enum ProfileProber {
    /// `password` is the in-progress password typed into the editor — threaded
    /// through so a brand-new/unsaved password profile (no Keychain reference
    /// yet) can authenticate. `ExplicitPasswordProvider` falls back to the
    /// stored Keychain password when it's empty, so the saved-profile probe
    /// path is unchanged.
    static func probe(profile: ServerProfile, password: String = "", confirmer: HostKeyConfirmer?) async throws -> HermesProbeResult {
        let runner = NIOSSHCommandRunner(
            profile: profile,
            credentialProvider: ExplicitPasswordProvider(password: password),
            hostKeyStore: ServerWindowHarness.sharedPinnedHostKeyStore,
            hostKeyConfirmer: confirmer
        )
        return try await NIOHermesProbe(runner: runner).probe(profile: profile)
    }
}

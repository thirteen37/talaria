import HermesKit

/// Capability probe seam (iOS) — mirror of `Platform/macOS/ProfileProber.swift`.
/// Drives the `#if`-free `NIOHermesProbe` over a `NIOSSHCommandRunner` wired
/// with the same `FileIdentityProvider` + shared pinned host-key store the
/// window uses, so a host trusted by the chat transport probes silently. A
/// first probe of a brand-new host surfaces the trust prompt via `confirmer`.
enum ProfileProber {
    static func probe(profile: ServerProfile, confirmer: HostKeyConfirmer?) async throws -> HermesProbeResult {
        let runner = NIOSSHCommandRunner(
            profile: profile,
            credentialProvider: FileIdentityProvider(),
            hostKeyStore: ServerWindowHarness.sharedPinnedHostKeyStore,
            hostKeyConfirmer: confirmer
        )
        return try await NIOHermesProbe(runner: runner).probe(profile: profile)
    }
}

import Foundation
import HermesKit

/// Per-profile dashboard lifecycle for the Talaria app (macOS). Owns one
/// `DashboardSupervisor` per profile, reference-counted so multiple windows
/// scoped to the same profile share a single `hermes dashboard` process. iOS
/// owns its supervisor directly on the harness (no cross-window sharing), so
/// this coordinator is macOS-only.
@MainActor
final class DashboardCoordinator {
    static let shared = DashboardCoordinator()

    /// Cache key: a window's default dashboard and an editor's profile-scoped
    /// dashboard are distinct processes for the same `ServerProfile`, so the
    /// Hermes profile name (`default` for the window dashboard, a named profile
    /// for the editor) joins the profile id in the key.
    private struct DashboardKey: Hashable {
        let profileId: UUID
        let hermesProfile: String
    }

    private var supervisors: [DashboardKey: DashboardSupervisor] = [:]
    private let http: any DashboardHTTP = URLSession.shared

    /// Acquires the dashboard for `profile`, scoped to `hermesProfileName`
    /// (`default` for the shared window dashboard), returning the endpoint and
    /// the supervisor that owns it. Callers hold the returned supervisor and
    /// pass it back to ``release(_:)`` rather than re-looking-up by key — the
    /// cached supervisor can be swapped out from under them by a profile edit,
    /// so key-only release would target the wrong instance.
    /// Returns the cached-or-fresh supervisor for `profile` *without* acquiring
    /// it, so a caller can store the instance before awaiting `acquire()` — and
    /// thus force-release the exact supervisor if a reconnect/teardown fires
    /// mid-acquire. Mirrors the iOS harness, which owns its supervisor up front.
    /// (Acquiring inline and assigning only after the await leaves a window where
    /// a reconnect can't see the in-flight supervisor and leaks its refcount.)
    func ensureSupervisor(
        for profile: ServerProfile,
        hermesProfileName: String = HermesProfiles.defaultProfileName
    ) -> DashboardSupervisor {
        ensure(profile: profile, hermesProfileName: hermesProfileName)
    }

    func acquire(
        profile: ServerProfile,
        hermesProfileName: String = HermesProfiles.defaultProfileName,
        onStartupProgress: (@Sendable (DashboardStartupPhase) async -> Void)? = nil
    ) async throws -> (DashboardEndpoint, DashboardSupervisor) {
        let supervisor = ensure(profile: profile, hermesProfileName: hermesProfileName)
        let endpoint = try await supervisor.acquire(onStartupProgress: onStartupProgress)
        return (endpoint, supervisor)
    }

    /// Tears down `supervisor`'s dashboard unconditionally (ignoring refcount)
    /// and evicts it, so the next ``acquire(profile:hermesProfileName:)`` for
    /// that profile builds a fresh process. The reconnect path: used when a live
    /// dashboard is wedged (dropped ssh forward, crashed/restarted remote) and a
    /// refcounted ``release(_:)`` wouldn't kill a still-shared process. Windows
    /// sharing the profile recover on their own next acquire/reconnect.
    func forceRelease(_ supervisor: DashboardSupervisor) async {
        await supervisor.forceShutdown()
        let key = DashboardKey(
            profileId: supervisor.profile.id,
            hermesProfile: supervisor.hermesProfileName ?? HermesProfiles.defaultProfileName
        )
        if supervisors[key] === supervisor {
            supervisors[key] = nil
        }
    }

    func release(_ supervisor: DashboardSupervisor) async {
        await supervisor.release()
        // Evict once fully released so the next acquire rebuilds against the
        // current profile config — but only if this instance is still the
        // cached one (a profile edit may have already replaced it).
        let key = DashboardKey(
            profileId: supervisor.profile.id,
            hermesProfile: supervisor.hermesProfileName ?? HermesProfiles.defaultProfileName
        )
        if supervisors[key] === supervisor, await supervisor.isFullyReleased {
            supervisors[key] = nil
        }
    }

    private func ensure(profile: ServerProfile, hermesProfileName: String) -> DashboardSupervisor {
        let key = DashboardKey(profileId: profile.id, hermesProfile: hermesProfileName)
        // Reuse only when the cached supervisor was built from the same profile
        // config. A profile edit keeps the id but changes hermesPath / host /
        // port / dashboardPort, so an id-only match would spawn the dashboard
        // with stale settings (or reuse a process started with them). The
        // displaced supervisor is still held + released by the harness that
        // acquired it, so its process is torn down — no leak.
        if let existing = supervisors[key], existing.profile == profile {
            return existing
        }
        let isDefault = hermesProfileName == HermesProfiles.defaultProfileName
        let supervisor = DashboardSupervisor(
            profile: profile,
            hermesProfileName: isDefault ? nil : hermesProfileName,
            launcher: launcher(for: profile),
            http: http,
            portAllocator: {
                // Only the default dashboard may bind the profile's fixed
                // `dashboardPort`; a named scope must allocate a fresh port so
                // it doesn't collide with the already-running default process.
                if isDefault, let port = profile.dashboardPort {
                    return port
                }
                return try DashboardPortAllocator.allocate()
            }
        )
        supervisors[key] = supervisor
        return supervisor
    }

    /// Local profiles need the login-shell PATH injected (a Finder/Dock-launched
    /// app's environment lacks Homebrew dirs), or `/usr/bin/env hermes dashboard`
    /// can't find a non-absolute `hermes` and the spawn exits before reachable.
    /// Mirrors `PathAwareHermesAdminRunner` for the admin path.
    private func launcher(for profile: ServerProfile) -> any DashboardProcessLauncher {
        switch profile.kind {
        case .local:
            return PathAugmentingDashboardLauncher(
                inner: SystemDashboardProcessLauncher(),
                resolver: LoginShellPATHResolver.shared
            )
        case .ssh:
            return SystemDashboardProcessLauncher()
        }
    }
}

/// Wraps a `DashboardProcessLauncher` to merge the resolved login-shell
/// environment (PATH, etc.) under the spec's own environment before launch.
/// The spec's values win, so an explicit `HERMES_HOME` / `profile.env` still
/// takes precedence over the login-shell PATH.
struct PathAugmentingDashboardLauncher: DashboardProcessLauncher {
    let inner: any DashboardProcessLauncher
    let resolver: LoginShellPATHResolver

    func launch(spec: DashboardSpawnSpec) async throws -> any DashboardProcess {
        var environment = await resolver.extraEnv()
        for (key, value) in spec.environment {
            environment[key] = value
        }
        let augmented = DashboardSpawnSpec(
            executable: spec.executable,
            arguments: spec.arguments,
            environment: environment
        )
        return try await inner.launch(spec: augmented)
    }
}

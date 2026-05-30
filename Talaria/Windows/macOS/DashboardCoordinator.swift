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

    private var supervisors: [UUID: DashboardSupervisor] = [:]
    private let http: any DashboardHTTP = URLSession.shared

    /// Acquires the dashboard for `profile`, returning the endpoint and the
    /// supervisor that owns it. Callers hold the returned supervisor and pass
    /// it back to ``release(_:)`` rather than re-looking-up by id — the cached
    /// supervisor for an id can be swapped out from under them by a profile
    /// edit, so id-keyed release would target the wrong instance.
    func acquire(profile: ServerProfile) async throws -> (DashboardEndpoint, DashboardSupervisor) {
        let supervisor = ensure(profile: profile)
        let endpoint = try await supervisor.acquire()
        return (endpoint, supervisor)
    }

    func release(_ supervisor: DashboardSupervisor) async {
        await supervisor.release()
        // Evict once fully released so the next acquire rebuilds against the
        // current profile config — but only if this instance is still the
        // cached one (a profile edit may have already replaced it).
        if supervisors[supervisor.profile.id] === supervisor, await supervisor.isFullyReleased {
            supervisors[supervisor.profile.id] = nil
        }
    }

    private func ensure(profile: ServerProfile) -> DashboardSupervisor {
        // Reuse only when the cached supervisor was built from the same profile
        // config. A profile edit keeps the id but changes hermesPath / host /
        // port / dashboardPort, so an id-only match would spawn the dashboard
        // with stale settings (or reuse a process started with them). The
        // displaced supervisor is still held + released by the harness that
        // acquired it, so its process is torn down — no leak.
        if let existing = supervisors[profile.id], existing.profile == profile {
            return existing
        }
        let supervisor = DashboardSupervisor(
            profile: profile,
            launcher: launcher(for: profile),
            http: http,
            portAllocator: {
                if let port = profile.dashboardPort {
                    return port
                }
                return try DashboardPortAllocator.allocate()
            }
        )
        supervisors[profile.id] = supervisor
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

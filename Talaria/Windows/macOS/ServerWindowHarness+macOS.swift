import Foundation
import HermesKit

// macOS transport / admin / dashboard wiring for `ServerWindowHarness`. The iOS
// mirror lives in `Windows/iOS/ServerWindowHarness+iOS.swift`.
extension ServerWindowHarness {
    static func makeLocal(
        profile: ServerProfile,
        hermesProfileName: String = HermesProfiles.defaultProfileName
    ) -> ServerWindowHarness {
        let resolver = LoginShellPATHResolver.shared
        resolver.warm()
        let hermesPath = profile.hermesPath
        let hermesHome = profile.hermesHome
        // `-p <name>` is a global flag placed between the binary and the `acp`
        // subcommand; it collapses to nothing for the default profile.
        let acpArgs = [hermesPath] + HermesProfiles.cliFlag(hermesProfileName) + ["acp"]
        let manager = SessionManager {
            let extraEnv = await resolver.extraEnv()
            var environment = extraEnv
            if let hermesHome {
                environment["HERMES_HOME"] = hermesHome
            }
            let transport = LocalProcessTransport(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: acpArgs,
                environment: environment
            )
            try transport.start()
            return transport
        }
        // Mirror the session transport's binary + env so admin commands launch
        // the same hermes the chat session does. Without `profile.hermesPath`
        // here, admin always ran `env hermes …` — which works for chat (chat
        // uses the profile path) but breaks admin when the profile points at
        // an absolute path or a binary name PATH lookup can't find.
        // `COLUMNS=400` keeps hermes' Rich tables from truncating skill names
        // (and other cells) to ellipsis-suffixed strings the parser can't map
        // back to enable/disable commands. Hermes inherits stdout's tty
        // semantics from the parent; without a wide hint, Rich falls back to
        // its 80-col default whenever stdout is a pipe.
        var adminBaseEnv: [String: String] = ["COLUMNS": "400"]
        if let hermesHome {
            adminBaseEnv["HERMES_HOME"] = hermesHome
        }
        // Scope outermost: `-p <name>` is prepended to each admin command (except
        // the default profile and `profile …` subcommands) after PATH resolution
        // and binary selection have already shaped the inner command.
        let adminRunner = ProfileScopedHermesAdminRunner(
            inner: PathAwareHermesAdminRunner(
                inner: LocalHermesAdminRunner(hermesPath: hermesPath, environment: adminBaseEnv),
                resolver: resolver
            ),
            hermesProfileName: hermesProfileName
        )
        let store = SessionsStore(manager: manager, adminRunner: adminRunner)
        return ServerWindowHarness(store: store, profile: profile, hermesProfileName: hermesProfileName)
    }

    static func makeRemote(
        profile: ServerProfile,
        hermesProfileName: String = HermesProfiles.defaultProfileName
    ) -> ServerWindowHarness {
        let useNIO = preferNIOSSHTransport()
        let manager: SessionManager
        // Transport-appropriate remote-file reader for surfaces that read
        // files off the host (Profiles' config comparison). NIO `cat` with the
        // keychain/host-key wiring when NIO is active; nil on the system-ssh
        // path, where `HermesConfigReader` falls back to `SFTPSubprocessTransfer`.
        let snapshotTransfer: RemoteSnapshotTransfer?

        let hostKeyCoordinator = HostKeyConfirmationCoordinator()
        if useNIO {
            let credentialProvider: SSHCredentialProvider = FileIdentityProvider()
            let hostKeyStore = defaultHostKeyStore()
            let confirmer: HostKeyConfirmer = { host, port, fingerprint in
                await hostKeyCoordinator.confirm(host: host, port: port, fingerprint: fingerprint)
            }
            manager = SessionManager {
                let transport = try NIOSSHTransport(
                    profile: profile,
                    credentialProvider: credentialProvider,
                    hostKeyStore: hostKeyStore,
                    hostKeyConfirmer: confirmer,
                    hermesProfileName: hermesProfileName
                )
                try await transport.start()
                return transport
            }
            snapshotTransfer = NIOSSHCatTransfer(
                profile: profile,
                credentialProvider: credentialProvider,
                hostKeyStore: hostKeyStore,
                hostKeyConfirmer: confirmer
            )
        } else {
            manager = SessionManager {
                let transport = SSHTransport(
                    host: profile.host ?? "",
                    user: profile.user,
                    port: profile.port,
                    identityFile: profile.identityFile,
                    hermesPath: profile.hermesPath,
                    hermesHome: profile.hermesHome,
                    remoteShellMode: profile.remoteShellMode,
                    remoteShellPrefix: profile.remoteShellPrefix,
                    hermesProfileName: hermesProfileName
                )
                try transport.start()
                return transport
            }
            // nil → HermesConfigReader falls back to SFTPSubprocessTransfer.
            snapshotTransfer = nil
        }

        // Scope outermost so Tools/Doctor run under the window's Hermes profile;
        // `profile list` and the default profile stay unscoped.
        let admin: any HermesAdminRunning = ProfileScopedHermesAdminRunner(
            inner: RemoteHermesAdminRunner(profile: profile),
            hermesProfileName: hermesProfileName
        )
        let store = SessionsStore(
            manager: manager,
            adminRunner: admin,
            // Pause the open timeout while the trust prompt is up so a slow
            // fingerprint comparison doesn't tear down the pending connection.
            isAwaitingUserInput: { hostKeyCoordinator.pending != nil }
        )
        return ServerWindowHarness(
            store: store,
            profile: profile,
            hermesProfileName: hermesProfileName,
            snapshotTransfer: snapshotTransfer,
            hostKeyCoordinator: hostKeyCoordinator
        )
    }

    /// True if we should use the NIO transport for this profile. macOS keeps
    /// system-ssh as the default until the flag is flipped.
    static func preferNIOSSHTransport() -> Bool {
        UserDefaults.standard.bool(forKey: useNIOSSHTransportDefaultsKey)
    }

    /// Builds the trust store the NIO transport consults during the host-key
    /// callback. macOS layers the read-only `~/.ssh/known_hosts` over the
    /// pinned store so previously trusted hosts connect silently.
    static func defaultHostKeyStore() -> HostKeyStore {
        CompositeHostKeyStore(readers: [KnownHostsFileStore(), sharedPinnedHostKeyStore], writer: sharedPinnedHostKeyStore)
    }

    func startDashboard() {
        guard !dashboardStarted else { return }
        dashboardStarted = true
        dashboardTask = Task { [weak self] in
            await self?.acquireDashboard()
        }
    }

    /// Acquires the dashboard endpoint for this profile, publishing the
    /// resulting `DashboardClient` so views can observe it.
    func acquireDashboard() async {
        do {
            let (endpoint, supervisor) = try await DashboardCoordinator.shared.acquire(
                profile: profile,
                hermesProfileName: hermesProfileName
            )
            // Store before the cancellation check so `tearDown()` can release
            // the acquired refcount even if we bail out right after.
            dashboardSupervisor = supervisor
            try Task.checkCancellation()
            guard !dashboardReleased else { return }
            dashboardClient = endpoint.session.client()
            store.dashboardClient = dashboardClient
            dashboardError = nil
        } catch {
            guard !Task.isCancelled, !dashboardReleased else { return }
            dashboardClient = nil
            store.dashboardClient = nil
            dashboardError = error.localizedDescription
        }
    }

    /// Acquires a dashboard scoped to a *named* Hermes profile, separate from
    /// this window's shared dashboard. Used by the Configuration editor's
    /// comparison column to reach a profile other than the window's active one.
    /// The caller (the editor's `ScopedDashboardPool`) holds the returned
    /// supervisor and releases it via ``releaseScopedDashboard(_:)``.
    func acquireScopedDashboardClient(
        hermesProfileName: String
    ) async throws -> (DashboardSupervisor, DashboardClient) {
        let (endpoint, supervisor) = try await DashboardCoordinator.shared.acquire(
            profile: profile,
            hermesProfileName: hermesProfileName
        )
        return (supervisor, endpoint.session.client())
    }

    func releaseScopedDashboard(_ supervisor: DashboardSupervisor) async {
        await DashboardCoordinator.shared.release(supervisor)
    }

    /// Cancels long-lived per-window resources when the SwiftUI window
    /// disappears. Releases this window's refcount on the per-profile dashboard
    /// supervisor — the last release terminates the spawned `hermes dashboard`
    /// process. Explicit hook (rather than `deinit`) because Swift 6 makes
    /// MainActor deinits nonisolated.
    func tearDown() {
        if dashboardStarted, !dashboardReleased {
            dashboardReleased = true
            // Chain release behind the acquire task. Cancelling it doesn't stop
            // the supervisor's in-flight spawn (that inner Task doesn't inherit
            // cancellation), so if teardown beats the acquire task to
            // `DashboardCoordinator.acquire`, an independent release would find
            // no registered supervisor, no-op, and leak the spawned process.
            // Awaiting the acquire task first guarantees the supervisor is
            // registered (refcount 1) before we drop our refcount.
            let acquireTask = dashboardTask
            acquireTask?.cancel()
            dashboardTask = nil
            dashboardClient = nil
            store.dashboardClient = nil
            // Await the acquire task first so `dashboardSupervisor` is set
            // (acquire stores it before returning), then release that exact
            // instance. Strong `self` keeps the harness alive for the brief
            // release so the refcount actually drops.
            Task {
                await acquireTask?.value
                if let supervisor = self.dashboardSupervisor {
                    await DashboardCoordinator.shared.release(supervisor)
                }
            }
        }
        notifications.stop()
        doctor.cancelRun()
        updates?.cancelApply()
        updates = nil
    }
}

import Foundation
import HermesKit

// iOS transport / admin / dashboard wiring for `ServerWindowHarness`. Mirror of
// `Windows/macOS/ServerWindowHarness+macOS.swift`. iOS is NIO-SSH only (no
// system-ssh, no local hermes) and now reaches Tools/Doctor/Profiles via the
// `#if`-free `NIOSSHHermesAdminRunner`.
extension ServerWindowHarness {
    /// iOS can't run local hermes (no `Process` / `OneShotProcess`). The
    /// bundled local profile is hidden in the UI, but keep a stub so the shared
    /// `make` dispatch stays total — the transport throws if ever started.
    static func makeLocal(
        profile: ServerProfile,
        hermesProfileName: String = HermesProfiles.defaultProfileName
    ) -> ServerWindowHarness {
        // iOS can't run local hermes; this stub never opens a real session.
        let manager = SessionManager(backendFactory: { throw GatewayChatError.sessionNotReady })
        return ServerWindowHarness(
            store: SessionsStore(manager: manager, adminRunner: nil),
            profile: profile,
            hermesProfileName: hermesProfileName
        )
    }

    static func makeRemote(
        profile: ServerProfile,
        hermesProfileName: String = HermesProfiles.defaultProfileName
    ) -> ServerWindowHarness {
        let hostKeyCoordinator = HostKeyConfirmationCoordinator()
        let credentialProvider: SSHCredentialProvider = FileIdentityProvider()
        let hostKeyStore = defaultHostKeyStore()
        let confirmer: HostKeyConfirmer = { host, port, fingerprint in
            await hostKeyCoordinator.confirm(host: host, port: port, fingerprint: fingerprint)
        }
        // Live chat tunnels `/api/ws` over the window's live NIO-SSH dashboard
        // connection (filled into the box by `acquireDashboard()`).
        let tunnelBox = GatewayChatTunnelBox()
        let manager = SessionManager(
            backendFactory: GatewayChatBackend.makeFactory(tunnel: { tunnelBox.get() })
        )
        let snapshotTransfer = NIOSSHCatTransfer(
            profile: profile,
            credentialProvider: credentialProvider,
            hostKeyStore: hostKeyStore,
            hostKeyConfirmer: confirmer
        )
        // Cross-platform NIO admin runner over `exec`. Shares the window's
        // host-key trust + identity wiring so Tools/Doctor/Profiles connect on
        // the same auth policy as the chat transport (and don't re-prompt for a
        // key the chat transport already trusted).
        // Scope outermost so Tools/Doctor run under the window's Hermes profile;
        // `profile list` and the default profile stay unscoped.
        let admin: any HermesAdminRunning = ProfileScopedHermesAdminRunner(
            inner: NIOSSHHermesAdminRunner(
                profile: profile,
                credentialProvider: credentialProvider,
                hostKeyStore: hostKeyStore,
                hostKeyConfirmer: confirmer
            ),
            hermesProfileName: hermesProfileName
        )
        let store = SessionsStore(
            manager: manager,
            adminRunner: admin,
            // Pause the open timeout while the trust prompt is up so a slow
            // fingerprint comparison doesn't tear down the pending connection.
            isAwaitingUserInput: { hostKeyCoordinator.pending != nil },
            profileId: profile.id,
            notifier: ChatNotifier.shared
        )
        let harness = ServerWindowHarness(
            store: store,
            profile: profile,
            hermesProfileName: hermesProfileName,
            snapshotTransfer: snapshotTransfer,
            hostKeyCoordinator: hostKeyCoordinator
        )
        harness.chatTunnelBox = tunnelBox
        return harness
    }

    /// Only the pinned (TOFU) store exists on iOS — there's no `~/.ssh/known_hosts`.
    static func defaultHostKeyStore() -> HostKeyStore {
        sharedPinnedHostKeyStore
    }

    func startDashboard() {
        guard !dashboardStarted else { return }
        // iOS reaches the dashboard over NIO-SSH, so it requires a remote
        // server. Local profiles can't run hermes on-device.
        guard profile.kind == .ssh else {
            dashboardError = "Dashboard mode requires a remote (SSH) server."
            return
        }
        dashboardStarted = true
        dashboardTask = Task { [weak self] in
            await self?.acquireDashboard()
        }
    }

    /// Acquires the dashboard endpoint for this profile, publishing the
    /// resulting `DashboardClient` so views can observe it.
    func acquireDashboard() async {
        let (supervisor, connection) = makeIOSDashboardSupervisor(hermesProfileName: hermesProfileName)
        dashboardSupervisor = supervisor
        isBuildingWebUI = false
        do {
            let endpoint = try await supervisor.acquire(
                onWebUIBuildDetected: { [weak self] in await self?.markWebUIBuilding() }
            )
            try Task.checkCancellation()
            guard !dashboardReleased else { return }
            dashboardClient = endpoint.session.client()
            store.dashboardClient = dashboardClient
            dashboardError = nil
            isBuildingWebUI = false
            // Hand the live SSH connection + remote port to the chat factory so a
            // gateway-chat session can tunnel `/api/ws` over it.
            if let port = endpoint.baseURL.port {
                chatTunnelBox?.set(GatewayChatTunnel(
                    connection: connection,
                    remotePort: port,
                    session: endpoint.session
                ))
            }
            // Capture the live version now the dashboard is reachable, so
            // capability gating uses it over the profile's cached probe value.
            await refreshLiveVersion()
        } catch {
            guard !Task.isCancelled, !dashboardReleased else { return }
            dashboardClient = nil
            store.dashboardClient = nil
            isBuildingWebUI = false
            dashboardError = error.localizedDescription
        }
    }

    /// Force-tears-down the supervisor `reconnectDashboard()` is replacing, so
    /// the subsequent re-acquire builds a fresh dashboard. iOS owns its
    /// supervisor directly (no coordinator), so it shuts it down in place.
    func forceReleaseDashboardSupervisor(_ supervisor: DashboardSupervisor) async {
        // The chat tunnel rides this connection; drop it so a new session doesn't
        // open WS over the connection we're about to tear down (re-acquire refills
        // the box). A stale-tunnel open would just throw `sessionNotReady`
        // anyway, but clearing the box avoids the wasted attempt.
        chatTunnelBox?.set(nil)
        await supervisor.forceShutdown()
    }

    /// Acquires a dashboard scoped to a *named* Hermes profile, separate from
    /// this window's shared dashboard. Used by the Configuration editor's
    /// comparison column to reach a profile other than the window's active one.
    /// iOS owns its supervisors directly (no cross-window coordinator), so this
    /// builds a fresh NIO-SSH-backed supervisor; the caller holds and releases it.
    func acquireScopedDashboardClient(
        hermesProfileName: String
    ) async throws -> (DashboardSupervisor, DashboardClient) {
        // Scoped (config-editor) dashboards aren't the chat tunnel, so the
        // connection is unused here.
        let (supervisor, _) = makeIOSDashboardSupervisor(hermesProfileName: hermesProfileName)
        let endpoint = try await supervisor.acquire()
        return (supervisor, endpoint.session.client())
    }

    func releaseScopedDashboard(_ supervisor: DashboardSupervisor) async {
        await supervisor.release()
    }

    func tearDown() {
        if dashboardStarted, !dashboardReleased {
            dashboardReleased = true
            // Same chained-release reasoning as macOS, but the supervisor lives
            // on the harness rather than a shared coordinator. Await the acquire
            // task first so the supervisor has finished spawning (refcount 1)
            // before we release and tear down the SSH connection.
            let acquireTask = dashboardTask
            acquireTask?.cancel()
            dashboardTask = nil
            dashboardClient = nil
            store.dashboardClient = nil
            // Read `dashboardSupervisor` *after* the acquire task finishes — the
            // acquire body assigns it before spawning, so capturing it
            // synchronously here (teardown runs before that body) would miss it
            // and leak the SSH connection + remote process.
            Task {
                await acquireTask?.value
                await self.dashboardSupervisor?.release()
                self.dashboardSupervisor = nil
            }
        }
        doctor.cancelRun()
        updates?.cancelApply()
        updates = nil
    }

    /// Builds the iOS dashboard supervisor: a NIO-SSH connection that both
    /// execs `hermes dashboard` on the remote host and tunnels its HTTP over a
    /// `direct-tcpip` channel. Reuses the window's host-key trust coordinator
    /// and the shared pinned host-key store so the dashboard connection doesn't
    /// re-prompt for a key the chat transport already trusted.
    /// Returns the supervisor and the underlying SSH connection — the connection
    /// is also what the gateway chat tunnel rides (``acquireDashboard()`` stashes
    /// it for the default window dashboard).
    private func makeIOSDashboardSupervisor(
        hermesProfileName: String = HermesProfiles.defaultProfileName
    ) -> (DashboardSupervisor, NIOSSHDashboardConnection) {
        var confirmer: HostKeyConfirmer?
        if let coordinator = hostKeyCoordinator {
            confirmer = { host, port, fingerprint in
                await coordinator.confirm(host: host, port: port, fingerprint: fingerprint)
            }
        }
        let connection = NIOSSHDashboardConnection(
            profile: profile,
            credentialProvider: FileIdentityProvider(),
            hostKeyStore: Self.defaultHostKeyStore(),
            hostKeyConfirmer: confirmer
        )
        let profile = profile
        let isDefault = hermesProfileName == HermesProfiles.defaultProfileName
        let supervisor = DashboardSupervisor(
            profile: profile,
            hermesProfileName: isDefault ? nil : hermesProfileName,
            launcher: NIOSSHDashboardProcessLauncher(connection: connection),
            http: NIOSSHDashboardHTTP(connection: connection),
            portAllocator: {
                // No local forward on iOS, so this is purely the remote bind
                // port. Only the default dashboard honors an explicit profile
                // port; a named scope picks a fresh high ephemeral port so it
                // doesn't collide with the running default (collisions surface
                // as the supervisor's not-reachable error).
                if isDefault, let port = profile.dashboardPort { return port }
                return Int.random(in: 40000...60000)
            }
        )
        return (supervisor, connection)
    }
}

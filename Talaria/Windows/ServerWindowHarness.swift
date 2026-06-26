import HermesKit
import SwiftUI

/// Bundles the per-window state so we can rebuild it cleanly when the
/// window swaps profiles. The `SessionsStore` holds the live chat session
/// clients; making a fresh harness guarantees the previous profile's one tears
/// down before the new one boots.
///
/// Platform behavior (transport selection, admin runner, dashboard lifecycle,
/// host-key store) lives in `ServerWindowHarness+macOS` / `+iOS`, selected by
/// the `**/macOS/**` / `**/iOS/**` folder excludes — no `#if` here.
@MainActor
@Observable
final class ServerWindowHarness {
    let store: SessionsStore
    let profile: ServerProfile
    /// Window-scoped banner hub for the top-of-window strip. All hard errors
    /// (session, dashboard) and transient success/info notices route here; it
    /// rebuilds with the harness on a profile switch, so a stale window's
    /// banners never leak into the next profile. See ``BannerCenter``.
    let banners = BannerCenter()
    /// The active Hermes profile (`hermes -p <name>`) this window is scoped to.
    /// `default` for the unscoped install. Every consumer the harness bundles
    /// (chat session clients, admin runner, dashboard supervisor) is built for
    /// this name, so a switch tears the harness down and rebuilds — the same
    /// machinery a server switch uses. Does not persist: resets to `default`
    /// on launch and on every server switch.
    let hermesProfileName: String
    /// The SSH transfer built by `makeRemote` with this window's transport
    /// selection (NIO + keychain/host-key store when NIO is active or on iOS;
    /// nil on the system-ssh macOS path, where consumers fall back to
    /// `SFTPSubprocessTransfer`). Reused by surfaces that read remote files —
    /// e.g. Profiles' config comparison — so they honor the same auth + trust
    /// policy as Sessions/snapshot rather than hardcoding one transport.
    let snapshotTransfer: RemoteSnapshotTransfer?
    /// Runs arbitrary shell on the host where the profile lives (local `/bin/sh`
    /// on macOS, system-ssh or NIO-SSH remotely) — used by the Profiles screen's
    /// distribution **Publish** flow to drive `git`. Built per-platform next to
    /// `adminRunner`/`snapshotTransfer`; nil on the iOS local stub.
    let hostShell: HostShellRunning?
    /// Drives the trust-on-first-use prompt for unknown SSH host keys. Always
    /// present for SSH profiles; nil for the bundled local profile.
    let hostKeyCoordinator: HostKeyConfirmationCoordinator?
    /// The **unscoped** admin runner for this window's transport — the inner
    /// runner before `ProfileScopedHermesAdminRunner` prepends `-p`. Threaded
    /// here (mirroring `snapshotTransfer`/`hostShell`) so cross-profile surfaces
    /// can scope it to *any* named profile via
    /// ``ProfileSyncEngine/scopedRunnerProvider(base:)``. The window's own
    /// `store.adminRunner` is already scoped to `hermesProfileName`, so re-using
    /// it would double-scope (a window on a named profile would read that profile
    /// as "default"). Nil on the iOS local stub.
    let baseAdminRunner: (any HermesAdminRunning)?
    /// Doctor run state. Window-owned (not view-owned) so a "Run Doctor"
    /// capture survives Browse navigation that destroys `DoctorView`. Built in
    /// `init` because its dependency (`store.adminRunner`) is ready then.
    /// Cancelled in the platform `tearDown()`.
    let doctor: DoctorHarness
    /// "Update Hermes" check/apply state, backed by the `hermes update --check`
    /// CLI over `store.adminRunner`. Built eagerly in `init` (the admin runner
    /// is ready then, unlike the async dashboard client). Window-owned so an
    /// in-flight apply — and its streamed log — survives Browse navigation.
    /// Cancelled in `tearDown()`.
    var updates: UpdatesHarness?
    /// Live `DashboardClient` once the per-profile supervisor's process has
    /// come online. `nil` until acquired (or while a teardown is in flight),
    /// non-nil for the lifetime of the window's interest in the profile.
    /// Surfaces render a "connecting…" state while this is nil; the window
    /// sidebar surfaces `dashboardError` if acquisition failed.
    var dashboardClient: DashboardClient?
    var dashboardError: String?
    /// Non-nil while the spawning dashboard is still coming up, driving the
    /// window-wide startup banner so the long wait reads as progress rather than
    /// a stuck "connecting…". ``DashboardStartupPhase/buildingWebUI`` is the
    /// confirmed-build case (marker seen) — the banner may assert the build;
    /// ``DashboardStartupPhase/slowToStart`` is the unconfirmed "alive but not
    /// listening yet" case (the common remote, non-PTY path where the marker
    /// never streams) — the banner hedges. Set by the supervisor's progress
    /// callback during ``acquireDashboard()``; cleared once the client is live,
    /// on failure, and on ``reconnectDashboard()``.
    var startupPhase: DashboardStartupPhase?
    var dashboardTask: Task<Void, Never>?
    var dashboardStarted = false
    var dashboardReleased = false
    /// The dashboard supervisor this harness is using. macOS acquires it from
    /// the shared `DashboardCoordinator` (and releases back to it on teardown);
    /// iOS owns its supervisor directly (one window per profile, no cross-window
    /// refcount sharing). One stored slot serves both — the platform `tearDown`
    /// releases the exact instance it acquired.
    var dashboardSupervisor: DashboardSupervisor?
    /// Live Hermes version from the dashboard's `GET /api/status`, captured when
    /// the dashboard client is acquired (``refreshLiveVersion()``). Preferred
    /// over the profile's cached `hermes --version` probe (`profile.version`)
    /// for capability gating — see ``effectiveHermesVersion``.
    var liveHermesVersion: HermesVersion?

    /// Active memory provider name from `GET /api/memory` (`""` = built-in),
    /// resolved **once in the background** when the dashboard connects
    /// (``refreshMemoryProvider()``). Lets the Soul/Personalities/Memory
    /// destination gate its Hindsight tab on a cached value instead of paying
    /// for the round-trip on every switch. `nil` until first resolved.
    var activeMemoryProvider: String?

    /// iOS only: the live NIO-SSH dashboard tunnel the gateway chat factory rides
    /// for `/api/ws` (iOS has no loopback socket). Filled by `acquireDashboard()`
    /// once the dashboard connects; nil on macOS (which uses `DashboardCoordinator`)
    /// and before the dashboard is up.
    var chatTunnelBox: GatewayChatTunnelBox?

    /// True while a connection recovery is in flight — the manual Reconnect
    /// button and the iOS background→foreground auto-probe share it. A second
    /// trigger (a tap during an in-flight recovery, or a duplicate resume event)
    /// is a no-op, so the dashboard is never double-spawned and the
    /// "Reconnecting…" banner shows once. Declared here (extensions can't add
    /// stored properties) but only the recovery paths populate it.
    var isRecovering = false
    /// The in-flight recovery task. Stored so it's reachable for cancellation;
    /// the iOS background-resume path and the manual button both assign it.
    var recoveryTask: Task<Void, Never>?

    /// The version every capability banner should gate on: the **live**
    /// dashboard status version when known, else the profile's cached probe
    /// version. The cached value is captured once at probe time and never
    /// refreshed, so after a Hermes upgrade it goes stale and version-gated
    /// surfaces mis-banner (e.g. an MCP-capable 0.15.1 server still reading a
    /// cached 0.14.0). The running dashboard's own status is authoritative for
    /// "what's available right now"; the cached probe is only the fallback for
    /// before the dashboard has connected.
    var effectiveHermesVersion: HermesVersion? { liveHermesVersion ?? profile.version }

    init(
        store: SessionsStore,
        profile: ServerProfile,
        hermesProfileName: String = HermesProfiles.defaultProfileName,
        snapshotTransfer: RemoteSnapshotTransfer? = nil,
        hostShell: HostShellRunning? = nil,
        hostKeyCoordinator: HostKeyConfirmationCoordinator? = nil,
        baseAdminRunner: (any HermesAdminRunning)? = nil
    ) {
        self.store = store
        self.profile = profile
        self.hermesProfileName = hermesProfileName
        self.snapshotTransfer = snapshotTransfer
        self.hostShell = hostShell
        self.hostKeyCoordinator = hostKeyCoordinator
        self.baseAdminRunner = baseAdminRunner
        self.doctor = DoctorHarness(runner: store.adminRunner)
        self.updates = UpdatesHarness(runner: store.adminRunner)
    }

    /// Builds a harness backed by an in-process ``MockACPTransport`` for UI
    /// tests — no SSH, no admin runner, no snapshot.
    static func makeMock() -> ServerWindowHarness {
        let manager = SessionManager(backendFactory: { MockChatBackend() })
        let store = SessionsStore(manager: manager, adminRunner: nil)
        let profile = ServerProfile(name: "Mock Server", kind: .ssh, host: "mock.local")
        return ServerWindowHarness(store: store, profile: profile)
    }

    /// Resolves which profile a window should boot for the requested id. macOS
    /// (`Platform.supportsLocalProfile`) falls back to the bundled local
    /// profile so a window always has something to show; iOS is remote-only, so
    /// it prefers a real SSH entry and falls back to the first persisted server,
    /// returning nil when none are configured (the no-server empty state).
    static func resolveProfile(in directory: ProfileDirectory, requestedId: UUID) -> ServerProfile? {
        if Platform.supportsLocalProfile {
            return directory.profile(id: requestedId) ?? ProfileDirectory.localProfile
        }
        if let requested = directory.profile(id: requestedId), requested.kind != .local {
            return requested
        }
        return directory.profiles.first
    }

    /// Dispatches to the platform `makeLocal` / `makeRemote` (defined in the
    /// per-platform extensions), scoping every consumer to `hermesProfileName`
    /// (`default` for the unscoped install).
    static func make(
        profile: ServerProfile,
        hermesProfileName: String = HermesProfiles.defaultProfileName
    ) -> ServerWindowHarness {
        switch profile.kind {
        case .local:
            return makeLocal(profile: profile, hermesProfileName: hermesProfileName)
        case .ssh:
            return makeRemote(profile: profile, hermesProfileName: hermesProfileName)
        }
    }

    /// `UserDefaults` key honored on macOS to opt the remote dashboard transport
    /// (which the live-chat WebSocket rides) into the pure-Swift NIO-SSH path
    /// instead of the default system-ssh `-L` forward. Host-key trust consults
    /// `HostKeyStore` for the NIO
    /// path; system-ssh defers to `~/.ssh/known_hosts`. See
    /// `docs/security.md`. iOS always uses NIO regardless of this flag —
    /// system-ssh isn't available there. Flip the default in a later
    /// release and delete system-ssh one release after that.
    static let useNIOSSHTransportDefaultsKey = "HermesKit.useNIOSSHTransport"

    /// Forces a fresh dashboard connection from *any* state — the manual
    /// reconnect. It covers both the first-connect retry (a brand-new host not
    /// yet trusted when the harness booted fails the one-shot `startDashboard`
    /// and, before this, stayed broken until app relaunch) **and** a live
    /// dashboard that has since wedged (transient network failure, dropped
    /// `ssh -L` forward, crashed/restarted remote) — where the client is still
    /// non-nil but every call errors and a refcounted release wouldn't kill the
    /// process. It unconditionally tears the current supervisor's process down
    /// (`forceReleaseDashboardSupervisor`) before re-acquiring, so the dashboard
    /// is genuinely rebuilt. Manual, not an auto-loop: against a still-untrusted
    /// host on macOS an auto-retry would spin forever, so the user taps Reconnect
    /// once the cause is cleared. No-op once the window has released its
    /// dashboard, or while a recovery is already in flight (the in-flight one
    /// already rebuilds and re-resumes — a second tap would only double-spawn).
    /// Routes through ``performRecovery()`` (no liveness probe — the user tapped
    /// because something is wrong), which re-acquires the dashboard *and*
    /// re-resumes open live chats so a manual reconnect no longer leaves the
    /// open chat tabs dead.
    func reconnectDashboard() {
        guard !dashboardReleased, !isRecovering else { return }
        // Claim the recovery slot synchronously, before the async hop, so two taps
        // (or a tap racing a background→foreground probe) can't both pass the guard
        // and spawn concurrent recoveries. The task clears it in a `defer`.
        isRecovering = true
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isRecovering = false }
            await self.performRecovery()
        }
    }

    /// iOS / iPad background→foreground hook: probe the dashboard, and rebuild
    /// the connection **only if the probe fails** (the single SSH tunnel died or
    /// went half-open while the app was suspended). A live connection is left
    /// untouched, so a brief app-switch costs one cheap `/api/status` round-trip
    /// and never tears the session down. No-op before the dashboard has started,
    /// after it's released, or while a recovery is already running. The macOS
    /// `onResumeFromBackground` seam is a no-op, so this only fires on iOS/iPad.
    func recoverConnectionIfNeeded() {
        guard dashboardStarted, !dashboardReleased, !isRecovering else { return }
        // Claim the recovery slot synchronously (see `reconnectDashboard`): the probe
        // + dead-set read below are suspension points, so without this two foreground
        // events arriving close together could both pass the guard and run concurrent
        // recoveries on the same just-resumed session.
        isRecovering = true
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isRecovering = false }
            if await self.isDashboardAlive() {
                // HTTP is healthy, but the live-chat `/api/ws` socket is a separate
                // long-lived `direct-tcpip` channel on the same SSH connection — it
                // can die (gateway restart, channel reset) while HTTP still answers.
                // A passing probe would otherwise leave the open chats silently dead.
                // Re-resume only the affected sessions over the still-good tunnel.
                await self.recoverDeadLiveSessionsIfNeeded()
                return
            }
            await self.performRecovery()
        }
    }

    /// Re-resumes open live chats whose `/api/ws` stream died while the dashboard
    /// HTTP channel stayed healthy — the WS-death-after-a-passing-probe case. Unlike
    /// ``performRecovery()``, it does **not** tear the SSH tunnel down (it's still
    /// good), and it re-resumes **only the dead sessions** over it — each chat owns
    /// its own socket, so the healthy (possibly mid-stream) chats are left alone.
    /// No-op when nothing is dead. The caller (``recoverConnectionIfNeeded()``) holds
    /// the ``isRecovering`` claim for the duration.
    ///
    /// Best-effort by design: ``SessionsStore/deadLiveSessionIds()`` reads the
    /// per-session stream-ended flag that each pump sets only once it *observes* its
    /// socket end, which on resume can land after this read (the underlying SSH/WS
    /// layer surfaces a reset asynchronously, and no amount of yielding here forces
    /// it). A chat whose death hasn't surfaced yet is simply caught on the next
    /// background→foreground cycle, or via manual Reconnect — the same fallback the
    /// plan assigns to mid-session silent WS death (a proactive WS heartbeat is out
    /// of scope for v1). The far more common trigger — the whole SSH tunnel dying on
    /// suspend — fails the `/api/status` probe and routes to the full
    /// ``performRecovery()`` instead, which re-resumes every tab regardless of flags.
    func recoverDeadLiveSessionsIfNeeded() async {
        guard dashboardClient != nil else { return }
        let dead = await store.deadLiveSessionIds()
        guard !dead.isEmpty else { return }
        await store.recoverLiveSessions(limitedTo: dead)
    }

    /// Races a `GET /api/status` round-trip against a short deadline. A half-open
    /// SSH tunnel would otherwise hang until ``NIOSSHDashboardConnection``'s 30s
    /// request timeout; ``SessionsStore/withTimeout(_:isPaused:_:)`` cancels far
    /// sooner. Returns false on any throw, timeout, or missing client.
    func isDashboardAlive(timeout: TimeInterval = 4) async -> Bool {
        guard let client = dashboardClient else { return false }
        do {
            _ = try await SessionsStore.withTimeout(timeout) {
                try await client.getStatus()
            }
            return true
        } catch {
            return false
        }
    }

    /// Rebuilds the dashboard connection and re-resumes open live chats, behind a
    /// persistent "Reconnecting…" banner. Force-tears the current supervisor down
    /// (so the dead/half-open SSH tunnel is genuinely replaced), re-acquires
    /// (refilling `dashboardClient` and, on iOS, `chatTunnelBox`), and — if the
    /// client came back — ``SessionsStore/recoverLiveSessions()`` re-resumes the open
    /// tabs over the fresh tunnel. On failure, `acquireDashboard()` has already set
    /// `dashboardError`, which the banner bridge turns into the red error banner with
    /// the manual Reconnect action — graceful degradation, no new failure UI.
    ///
    /// The caller (``reconnectDashboard()`` / ``recoverConnectionIfNeeded()``) holds
    /// the ``isRecovering`` claim for the duration, so concurrent recoveries can't
    /// interleave.
    func performRecovery() async {
        banners.info("Reconnecting…", key: "reconnect", persist: true)
        defer { banners.dismiss(key: "reconnect") }

        dashboardTask?.cancel()
        let previous = dashboardSupervisor
        dashboardSupervisor = nil
        dashboardClient = nil
        store.dashboardClient = nil
        dashboardError = nil
        startupPhase = nil
        if let previous {
            await forceReleaseDashboardSupervisor(previous)
        }
        await acquireDashboard()
        if dashboardClient != nil {
            await store.recoverLiveSessions()
        }
    }

    /// Records the dashboard's startup phase, driving the progress banner.
    /// Invoked from the supervisor's progress callback (off-actor), so it hops
    /// here to mutate harness state.
    func noteStartupPhase(_ phase: DashboardStartupPhase) {
        guard dashboardClient == nil, !dashboardReleased else { return }
        startupPhase = phase
    }

    /// Refreshes ``liveHermesVersion`` from the connected dashboard's
    /// `GET /api/status`. Best-effort: a failure leaves the previous value (or
    /// nil), so ``effectiveHermesVersion`` falls back to the cached probe.
    /// Called from the platform `acquireDashboard()` once the client is live.
    func refreshLiveVersion() async {
        guard let dashboardClient else { return }
        if let status = try? await dashboardClient.getStatus() {
            liveHermesVersion = HermesVersion(status.version)
        }
    }

    /// Best-effort resolve of the active memory provider, cached so the
    /// Soul/Personalities/Memory destination's Hindsight-tab gate reads it
    /// synchronously. Called from the platform `acquireDashboard()` (background),
    /// and as a fallback by the destination if still unresolved.
    func refreshMemoryProvider() async {
        guard let dashboardClient else { return }
        if let status = try? await dashboardClient.getMemory() {
            activeMemoryProvider = status.active
        }
    }

    /// Process-wide singleton. `PinnedHostKeyStore`'s read-modify-write
    /// atomicity is enforced by an `NSLock` *on the instance* — handing
    /// each `ServerWindowHarness` its own instance would re-introduce
    /// the lost-update window when two windows confirm TOFU pins at the
    /// same time, since both writers would hold different locks while
    /// racing the same JSON file. Sharing the instance keeps the lock
    /// effective across windows.
    ///
    /// `nonisolated` because it's an immutable, thread-safe (`NSLock`-guarded)
    /// store shared across actors — the `ProfileProber` seam reads it off the
    /// main actor to build the probe's command runner.
    nonisolated static let sharedPinnedHostKeyStore = PinnedHostKeyStore()
}

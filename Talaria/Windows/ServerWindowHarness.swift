import HermesKit
import SwiftUI

/// Bundles the per-window state so we can rebuild it cleanly when the
/// window swaps profiles. The `SessionsStore` holds the live ACP transport;
/// making a fresh harness guarantees the previous profile's one tears down
/// before the new one boots.
///
/// Platform behavior (transport selection, admin runner, dashboard lifecycle,
/// host-key store) lives in `ServerWindowHarness+macOS` / `+iOS`, selected by
/// the `**/macOS/**` / `**/iOS/**` folder excludes — no `#if` here.
@MainActor
@Observable
final class ServerWindowHarness {
    let store: SessionsStore
    let profile: ServerProfile
    /// The active Hermes profile (`hermes -p <name>`) this window is scoped to.
    /// `default` for the unscoped install. Every consumer the harness bundles
    /// (ACP transport, admin runner, dashboard supervisor) is built for this
    /// name, so a switch tears the harness down and rebuilds — the same
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
    /// Drives the trust-on-first-use prompt for unknown SSH host keys. Always
    /// present for SSH profiles; nil for the bundled local profile.
    let hostKeyCoordinator: HostKeyConfirmationCoordinator?
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
    /// True while the spawning dashboard is compiling its web UI (first
    /// `hermes dashboard` after a Hermes update). Drives the window-wide
    /// "Building web UI…" banner so the long wait reads as progress rather than
    /// a stuck "connecting…". Set by the supervisor's build callback during
    /// ``acquireDashboard()``; cleared once the client is live, on failure, and
    /// on ``reconnectDashboard()``.
    var isBuildingWebUI = false
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

    /// Shared with the chat backend factory so it can gate WS-vs-ACP selection on
    /// the live version at session-open time (the factory is built before the
    /// dashboard — and thus the version — is known). `refreshLiveVersion()` pushes
    /// the resolved version here. nil on windows that don't use gateway chat.
    var chatVersionBox: LiveVersionBox?

    /// iOS only: the live NIO-SSH dashboard tunnel the gateway chat factory rides
    /// for `/api/ws` (iOS has no loopback socket). Filled by `acquireDashboard()`
    /// once the dashboard connects; nil on macOS (which uses `DashboardCoordinator`)
    /// and before the dashboard is up.
    var chatTunnelBox: GatewayChatTunnelBox?

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
        hostKeyCoordinator: HostKeyConfirmationCoordinator? = nil
    ) {
        self.store = store
        self.profile = profile
        self.hermesProfileName = hermesProfileName
        self.snapshotTransfer = snapshotTransfer
        self.hostKeyCoordinator = hostKeyCoordinator
        self.doctor = DoctorHarness(runner: store.adminRunner)
        self.updates = UpdatesHarness(runner: store.adminRunner)
    }

    /// Builds a harness backed by an in-process ``MockACPTransport`` for UI
    /// tests — no SSH, no admin runner, no snapshot.
    static func makeMock() -> ServerWindowHarness {
        let manager = SessionManager { MockACPTransport() }
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

    /// `UserDefaults` key honored on macOS to opt the ACP transport into
    /// the pure-Swift NIO-SSH path instead of the default system-ssh
    /// subprocess. Host-key trust consults `HostKeyStore` for the NIO
    /// path; system-ssh defers to `~/.ssh/known_hosts`. See
    /// `docs/security.md`. iOS always uses NIO regardless of this flag —
    /// system-ssh isn't available there. Flip the default in a later
    /// release and delete system-ssh one release after that.
    static let useNIOSSHTransportDefaultsKey = "HermesKit.useNIOSSHTransport"

    /// Opt-in: drive live chat over the dashboard `/api/ws` JSON-RPC gateway
    /// (the same path Hermes Desktop uses) instead of spawning a separate
    /// `hermes acp` subprocess. Default off while the WebSocket path reaches
    /// parity; gated additionally on the connected Hermes version
    /// (`HermesCapability.gatewayChat`). macOS only for now — the iOS NIO-SSH
    /// path needs `NIOSSHGatewayWebSocket` (Phase 3). See `docs/gateway-chat.md`.
    ///
    /// `nonisolated` so the per-session backend factory (`@Sendable`) and
    /// `preferGatewayChat()` can read it off the main actor.
    nonisolated static let useGatewayChatDefaultsKey = "HermesKit.useGatewayChat"

    /// User opt-in for driving live chat over the dashboard `/api/ws` gateway
    /// instead of the ACP subprocess (the `useGatewayChat` default, toggled in
    /// Settings → Developer). The actual per-session choice also requires the
    /// connected Hermes to advertise `HermesCapability.gatewayChat` — the
    /// platform `GatewayChatBackend.makeSelectingFactory` falls back to ACP
    /// otherwise — so flipping this against an older server is safe.
    ///
    /// `nonisolated` so the per-session backend factory (a `@Sendable` closure)
    /// can read it; it only touches `UserDefaults`, which is thread-safe.
    nonisolated static func preferGatewayChat() -> Bool {
        UserDefaults.standard.bool(forKey: useGatewayChatDefaultsKey)
    }

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
    /// dashboard.
    func reconnectDashboard() {
        guard !dashboardReleased else { return }
        dashboardTask?.cancel()
        dashboardError = nil
        isBuildingWebUI = false
        let previous = dashboardSupervisor
        dashboardSupervisor = nil
        dashboardClient = nil
        store.dashboardClient = nil
        dashboardTask = Task { [weak self] in
            if let previous { await self?.forceReleaseDashboardSupervisor(previous) }
            await self?.acquireDashboard()
        }
    }

    /// Flips on the "Building web UI…" banner. Invoked from the supervisor's
    /// build callback (off-actor), so it hops here to mutate harness state.
    func markWebUIBuilding() {
        guard dashboardClient == nil, !dashboardReleased else { return }
        isBuildingWebUI = true
    }

    /// Refreshes ``liveHermesVersion`` from the connected dashboard's
    /// `GET /api/status`. Best-effort: a failure leaves the previous value (or
    /// nil), so ``effectiveHermesVersion`` falls back to the cached probe.
    /// Called from the platform `acquireDashboard()` once the client is live.
    func refreshLiveVersion() async {
        guard let dashboardClient else { return }
        if let status = try? await dashboardClient.getStatus() {
            liveHermesVersion = HermesVersion(status.version)
            // Let the chat backend factory see the version for WS-vs-ACP gating.
            chatVersionBox?.set(liveHermesVersion)
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

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
    /// Aggregates cross-cutting issues (update available, doctor failure)
    /// for the bell + notifications detail page. Built once per harness;
    /// cancelled in `tearDown()`.
    let notifications: WindowNotificationCenter
    /// Live `DashboardClient` once the per-profile supervisor's process has
    /// come online. `nil` until acquired (or while a teardown is in flight),
    /// non-nil for the lifetime of the window's interest in the profile.
    /// Surfaces render a "connecting…" state while this is nil; the window
    /// sidebar surfaces `dashboardError` if acquisition failed.
    var dashboardClient: DashboardClient?
    var dashboardError: String?
    var dashboardTask: Task<Void, Never>?
    var dashboardStarted = false
    var dashboardReleased = false
    /// The dashboard supervisor this harness is using. macOS acquires it from
    /// the shared `DashboardCoordinator` (and releases back to it on teardown);
    /// iOS owns its supervisor directly (one window per profile, no cross-window
    /// refcount sharing). One stored slot serves both — the platform `tearDown`
    /// releases the exact instance it acquired.
    var dashboardSupervisor: DashboardSupervisor?

    init(
        store: SessionsStore,
        profile: ServerProfile,
        snapshotTransfer: RemoteSnapshotTransfer? = nil,
        hostKeyCoordinator: HostKeyConfirmationCoordinator? = nil
    ) {
        self.store = store
        self.profile = profile
        self.snapshotTransfer = snapshotTransfer
        self.hostKeyCoordinator = hostKeyCoordinator
        self.notifications = WindowNotificationCenter(adminRunner: store.adminRunner)
        self.notifications.start()
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
    /// per-platform extensions).
    static func make(profile: ServerProfile) -> ServerWindowHarness {
        switch profile.kind {
        case .local:
            return makeLocal(profile: profile)
        case .ssh:
            return makeRemote(profile: profile)
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

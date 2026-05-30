import HermesKit
import SwiftUI

/// View-model for the Configuration surface. Edits the window's **active** Hermes
/// profile: the window dashboard is already scoped to it (`hermes -p <name>`), so
/// the `source` editing state reads that profile through the window's shared
/// client rather than acquiring its own. There is no in-editor profile picker —
/// the primary profile is chosen by the window's top-level switcher.
///
/// Comparison is additive (desktop only): a second editing state (`dest`) targets
/// another profile and reaches it through the name-keyed `ScopedDashboardPool`,
/// since the window client only serves the active profile. iPhone reuses this
/// harness and simply never compares.
@MainActor
@Observable
final class ConfigEditorHarness {
    typealias Mode = ConfigEditingState.Mode

    /// Profiles on the server (from the window) — the compare dropdown's options.
    /// Mutable because the window's enumeration can land after the editor opens
    /// (a slow remote `profile list`); the container feeds updates in via
    /// ``setAvailableProfiles(_:)`` so the dropdown isn't stuck empty.
    private(set) var profiles: [HermesProfileInfo]
    /// The Hermes profile this editor edits (the window's active profile). The
    /// source column is fixed to it; it's also the comparison's source side.
    let editedProfileName: String

    /// Editing state for the edited (window-active) profile.
    private(set) var source: ConfigEditingState

    // Comparison (desktop only): a second editing state bound to `compareProfile`.
    // `comparing` is derived from its presence.
    private(set) var dest: ConfigEditingState?
    var compareProfile: String = ""
    var comparing: Bool { dest != nil }

    /// Profile-list error (config errors live on the editing states).
    var lastError: String?

    // Dependencies
    private let defaultClientProvider: @MainActor () -> DashboardClient?
    private let serverProfile: ServerProfile
    private let transfer: RemoteSnapshotTransfer?
    private let pool: ScopedDashboardPool<DashboardSupervisor, DashboardClient>

    // Serializes compare-state transitions (build/teardown of `dest`) so rapid
    // toggles don't fire concurrent first-connections that race host-key
    // verification, and so a teardown can't run before its build completes.
    private var compareTask: Task<Void, Never>?

    init(
        profiles: [HermesProfileInfo],
        editedProfileName: String,
        defaultClient: @escaping @MainActor () -> DashboardClient?,
        profile: ServerProfile,
        transfer: RemoteSnapshotTransfer?,
        acquireScoped: @escaping @MainActor (String) async throws -> (DashboardSupervisor, DashboardClient),
        releaseScoped: @escaping @MainActor (DashboardSupervisor) async -> Void
    ) {
        self.profiles = profiles
        self.editedProfileName = editedProfileName
        self.defaultClientProvider = defaultClient
        self.serverProfile = profile
        self.transfer = transfer
        let pool = ScopedDashboardPool<DashboardSupervisor, DashboardClient>(
            acquire: acquireScoped,
            release: releaseScoped
        )
        self.pool = pool
        self.compareProfile = profiles.first(where: { $0.name != editedProfileName })?.name ?? ""
        self.source = ConfigEditorHarness.makeState(
            for: editedProfileName,
            editedProfileName: editedProfileName,
            defaultClient: defaultClient,
            serverProfile: profile,
            transfer: transfer,
            pool: pool
        )
    }

    private static func makeState(
        for name: String,
        editedProfileName: String,
        defaultClient: @escaping @MainActor () -> DashboardClient?,
        serverProfile: ServerProfile,
        transfer: RemoteSnapshotTransfer?,
        pool: ScopedDashboardPool<DashboardSupervisor, DashboardClient>
    ) -> ConfigEditingState {
        ConfigEditingState(
            profileName: name,
            // The window dashboard is scoped to the active profile, so that
            // column reads the shared client; any other profile is pool-scoped.
            usesWindowClient: name == editedProfileName,
            defaultClient: defaultClient,
            serverProfile: serverProfile,
            transfer: transfer,
            acquireScoped: { try await pool.acquire($0) },
            releaseScoped: { await pool.release($0) }
        )
    }

    private func makeState(for name: String) -> ConfigEditingState {
        ConfigEditorHarness.makeState(
            for: name,
            editedProfileName: editedProfileName,
            defaultClient: defaultClientProvider,
            serverProfile: serverProfile,
            transfer: transfer,
            pool: pool
        )
    }

    var isLoading: Bool { source.isLoading }

    // MARK: - Loading

    func start() async {
        source.load()
    }

    func refresh() async {
        source.load()
        dest?.load()
    }

    /// Refreshes the compare dropdown's options when the window's enumeration
    /// lands after the editor opened. Preserves a still-valid compare choice;
    /// otherwise re-defaults it (rebuilding `dest` if a comparison is active and
    /// its target vanished).
    func setAvailableProfiles(_ newProfiles: [HermesProfileInfo]) {
        guard newProfiles != profiles else { return }
        profiles = newProfiles
        let compareStillValid = !compareProfile.isEmpty
            && newProfiles.contains(where: { $0.name == compareProfile })
        guard !compareStillValid else { return }
        compareProfile = newProfiles.first(where: { $0.name != editedProfileName })?.name ?? ""
        if comparing {
            if compareProfile.isEmpty {
                stopComparing()
            } else {
                buildDest(for: compareProfile)
            }
        }
    }

    /// Re-runs the load when the window's dashboard comes online after an initial
    /// degraded render. The internal guard limits this to the window-client
    /// state(s), so a pool-scoped `dest` is unaffected.
    func reloadIfDashboardAppeared() {
        source.reloadIfDashboardAppeared()
        dest?.reloadIfDashboardAppeared()
    }

    /// Releases every profile-scoped dashboard this editor acquired. Call from
    /// the view's teardown. Awaits in-flight load/compare chains first, then tears
    /// down both states and drains the pool as a backstop so no supervisor leaks.
    func teardown() async {
        compareTask?.cancel()
        await compareTask?.value
        await source.teardown()
        await dest?.teardown()
        await pool.drain()
    }

    // MARK: - Mode switching

    func setMode(_ newMode: Mode) {
        source.setMode(newMode)
    }

    // MARK: - Comparison (desktop, editable two-column)

    func toggleComparing() {
        if comparing {
            stopComparing()
        } else {
            if compareProfile.isEmpty || compareProfile == editedProfileName {
                compareProfile = profiles.first(where: { $0.name != editedProfileName })?.name ?? ""
            }
            guard !compareProfile.isEmpty else { return }
            buildDest(for: compareProfile)
        }
    }

    func setCompareProfile(_ name: String) {
        guard name != compareProfile, name != editedProfileName else { return }
        compareProfile = name
        buildDest(for: name)
    }

    /// Builds the dest editing state for `name` and starts its load behind any
    /// previous compare work. The dest acquire is sequenced **after** the source
    /// side's in-flight load so two first-connections don't race host-key
    /// verification on the NIO transport (concurrent verifications fail one side).
    private func buildDest(for name: String) {
        let previousTask = compareTask
        let previousDest = dest
        let newDest = makeState(for: name)
        dest = newDest
        compareTask = Task { [weak self] in
            await previousTask?.value
            await previousDest?.teardown()
            await self?.source.awaitCurrentLoad()
            if Task.isCancelled { return }
            newDest.load()
        }
    }

    private func stopComparing() {
        let previousTask = compareTask
        let previousDest = dest
        dest = nil
        compareTask = Task {
            await previousTask?.value
            await previousDest?.teardown()
        }
    }
}

import HermesKit
import SwiftUI

/// View-model for the Profiles config surface. Owns the profile list/selection,
/// a name-keyed scoped-dashboard pool, and the `source` editing state for the
/// selected profile. Comparison is additive — desktop reveals a second editing
/// state (`dest`); iPhone reuses the same harness and simply never compares.
///
/// The dashboard is reached only through injected `acquireScoped`/`releaseScoped`
/// closures (the window harness wires the macOS coordinator or the iOS
/// supervisor), so this type stays platform-neutral.
@MainActor
@Observable
final class ConfigEditorHarness {
    typealias Mode = ConfigEditingState.Mode

    // Profile selection
    var profiles: [HermesProfileInfo] = []
    private(set) var selectedProfile: String
    /// Set when `hermes profile list` is too old to exist; the editor still
    /// works against the single `default` profile.
    var profilesUnavailable = false

    /// Editing state for the selected profile. Rebuilt on every selection change
    /// so each instance is immutably scoped to one profile.
    private(set) var source: ConfigEditingState

    // Comparison (desktop only): a second editing state bound to `compareProfile`.
    // `comparing` is derived from its presence.
    private(set) var dest: ConfigEditingState?
    var compareProfile: String = ""
    var comparing: Bool { dest != nil }
    /// Visual-only filter for the editable comparison: hides rows whose values
    /// match on both sides. Affects only which rows render, never the underlying
    /// editing states.
    var showDifferencesOnly = false

    /// Profile-list error (config errors live on the editing states).
    var lastError: String?

    // Dependencies
    private let defaultClientProvider: @MainActor () -> DashboardClient?
    private let runner: HermesAdminRunning?
    private let serverProfile: ServerProfile
    private let transfer: RemoteSnapshotTransfer?
    private let pool: ScopedDashboardPool<DashboardSupervisor, DashboardClient>

    // Serializes compare-state transitions (build/teardown of `dest`) so rapid
    // toggles don't fire concurrent first-connections that race host-key
    // verification, and so a teardown can't run before its build completes.
    private var compareTask: Task<Void, Never>?

    init(
        selectedProfile: String = HermesProfiles.defaultProfileName,
        defaultClient: @escaping @MainActor () -> DashboardClient?,
        runner: HermesAdminRunning?,
        profile: ServerProfile,
        transfer: RemoteSnapshotTransfer?,
        acquireScoped: @escaping @MainActor (String) async throws -> (DashboardSupervisor, DashboardClient),
        releaseScoped: @escaping @MainActor (DashboardSupervisor) async -> Void
    ) {
        self.selectedProfile = selectedProfile
        self.defaultClientProvider = defaultClient
        self.runner = runner
        self.serverProfile = profile
        self.transfer = transfer
        let pool = ScopedDashboardPool<DashboardSupervisor, DashboardClient>(
            acquire: acquireScoped,
            release: releaseScoped
        )
        self.pool = pool
        self.source = ConfigEditorHarness.makeState(
            for: selectedProfile,
            defaultClient: defaultClient,
            serverProfile: profile,
            transfer: transfer,
            pool: pool
        )
    }

    private static func makeState(
        for name: String,
        defaultClient: @escaping @MainActor () -> DashboardClient?,
        serverProfile: ServerProfile,
        transfer: RemoteSnapshotTransfer?,
        pool: ScopedDashboardPool<DashboardSupervisor, DashboardClient>
    ) -> ConfigEditingState {
        ConfigEditingState(
            profileName: name,
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
            defaultClient: defaultClientProvider,
            serverProfile: serverProfile,
            transfer: transfer,
            pool: pool
        )
    }

    var isLoading: Bool { source.isLoading }

    // MARK: - Loading

    func start() async {
        await loadProfiles()
        source.load()
    }

    func refresh() async {
        await loadProfiles()
        source.load()
        dest?.load()
    }

    func loadProfiles() async {
        // Prefer the dashboard API: it returns clean names + a structured
        // is-default flag, where the CLI `hermes profile list` decorates the
        // default row with a marker glyph that leaks into the parsed name.
        if let client = defaultClientProvider() {
            do {
                let list = try await client.listProfiles()
                profiles = list.map { HermesProfileInfo(name: $0.name, isDefault: $0.isDefault, status: nil) }
                profilesUnavailable = false
                normalizeSelections()
                return
            } catch {
                // Fall through to the CLI source (dashboard down / too old).
            }
        }
        guard let runner else {
            profiles = [HermesProfileInfo(name: HermesProfiles.defaultProfileName, isDefault: true, status: nil)]
            normalizeSelections()
            return
        }
        do {
            profiles = try await HermesProfiles.list(runner: runner)
            profilesUnavailable = false
            normalizeSelections()
        } catch {
            handleProfilesError(error)
        }
    }

    /// Keeps the selected (and compare) profiles valid against the current list.
    private func normalizeSelections() {
        if !profiles.contains(where: { $0.name == selectedProfile }) {
            let resolved = profiles.first(where: \.isDefault)?.name
                ?? profiles.first?.name
                ?? HermesProfiles.defaultProfileName
            if resolved != selectedProfile {
                selectedProfile = resolved
                rebuildSource()
            }
        }
        if compareProfile.isEmpty || !profiles.contains(where: { $0.name == compareProfile }) {
            compareProfile = profiles.first(where: { $0.name != selectedProfile })?.name ?? ""
        }
    }

    /// Re-runs the load when the window's default dashboard comes online after an
    /// initial degraded render. Routes to whichever editing state(s) are bound to
    /// the default profile (either column of the comparison can be `default`).
    func reloadIfDashboardAppeared() {
        if source.profileName == HermesProfiles.defaultProfileName {
            source.reloadIfDashboardAppeared()
        }
        if dest?.profileName == HermesProfiles.defaultProfileName {
            dest?.reloadIfDashboardAppeared()
        }
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

    // MARK: - Profile / mode switching

    func selectProfile(_ name: String) async {
        guard name != selectedProfile else { return }
        selectedProfile = name
        rebuildSource()
        // While comparing, never let both columns target the same config: if the
        // new selection collides with the compare profile, bump it and rebuild
        // dest against the new source (collision-avoidance runs before acquiring).
        if comparing, compareProfile == name {
            compareProfile = profiles.first(where: { $0.name != name })?.name ?? ""
            buildDest(for: compareProfile)
        }
    }

    /// Swaps in a fresh editing state for the current selection and tears down the
    /// previous one (releasing its scoped hold) without blocking the UI.
    private func rebuildSource() {
        let previous = source
        source = makeState(for: selectedProfile)
        source.load()
        Task { await previous.teardown() }
    }

    func setMode(_ newMode: Mode) {
        source.setMode(newMode)
    }

    // MARK: - Comparison (desktop, editable two-column)

    func toggleComparing() {
        if comparing {
            stopComparing()
        } else {
            if compareProfile.isEmpty || compareProfile == selectedProfile {
                compareProfile = profiles.first(where: { $0.name != selectedProfile })?.name ?? ""
            }
            guard !compareProfile.isEmpty else { return }
            buildDest(for: compareProfile)
        }
    }

    func setCompareProfile(_ name: String) {
        guard name != compareProfile, name != selectedProfile else { return }
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

    private func handleProfilesError(_ error: Error) {
        if let profilesError = error as? HermesProfilesError, case .commandUnavailable = profilesError {
            profilesUnavailable = true
            profiles = [HermesProfileInfo(name: HermesProfiles.defaultProfileName, isDefault: true, status: nil)]
            return
        }
        lastError = error.localizedDescription
    }
}

import HermesKit
import SwiftUI

/// View-model for the Configuration surface. Edits the window's **active** Hermes
/// profile: the `source` editing state reads it through the window's shared
/// dashboard client (scoped via `?profile=<name>`). There is no in-editor profile
/// picker — the primary profile is chosen by the window's top-level switcher.
///
/// Comparison is additive (desktop only): a second editing state (`dest`) targets
/// another profile, reached by scoping the *same* window client to that profile.
/// iPhone reuses this harness and simply never compares.
@MainActor
@Observable
final class ConfigEditorHarness {
    typealias Mode = ConfigEditingState.Mode

    /// Profiles on the server (from the window) — the compare dropdown's options.
    /// Mutable because the window's enumeration can land after the editor opens
    /// (a slow remote `profile list`); the container feeds updates in via
    /// ``setAvailableProfiles(_:)`` so the dropdown isn't stuck empty.
    private(set) var profiles: [HermesProfileInfo]
    /// The window's **active** Hermes profile — the default for the comparison's
    /// source column when `sourceProfileName` isn't given. It is *not* necessarily
    /// the comparison's source (the sync surface pins that to `default`).
    let editedProfileName: String
    /// The comparison's **source** profile (the left/fixed column). Defaults to
    /// ``editedProfileName`` (the config editor edits the active profile), but the
    /// cross-profile sync surface pins it to `default` so every named profile is
    /// compared against default regardless of which profile the window is on.
    let sourceProfileName: String

    /// Editing state for the edited (window-active) profile.
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

    /// Profile-list error (config errors live on the editing states). Mirrors to
    /// the top-of-window strip keyed "config", alongside the source state's errors.
    var lastError: String? {
        didSet {
            if let lastError {
                banners?.surfaceError("config", lastError)
            } else {
                banners?.dismiss(key: "config")
            }
        }
    }

    /// Top-of-window banner hub (window-scoped); optional so a missing host
    /// degrades to no-op. Propagated to the source/dest editing states so their
    /// hard errors and the "Configuration saved" success route to the same strip.
    var banners: BannerCenter? {
        didSet {
            source.banners = banners
            dest?.banners = banners
        }
    }

    // Dependencies
    private let defaultClientProvider: @MainActor () -> DashboardClient?
    private let serverProfile: ServerProfile
    private let transfer: RemoteSnapshotTransfer?

    // Serializes compare-state transitions (build/teardown of `dest`) so rapid
    // toggles don't fire concurrent first-connections that race host-key
    // verification, and so a teardown can't run before its build completes.
    private var compareTask: Task<Void, Never>?

    init(
        profiles: [HermesProfileInfo],
        editedProfileName: String,
        sourceProfileName: String? = nil,
        defaultClient: @escaping @MainActor () -> DashboardClient?,
        profile: ServerProfile,
        transfer: RemoteSnapshotTransfer?
    ) {
        let sourceName = sourceProfileName ?? editedProfileName
        self.profiles = profiles
        self.editedProfileName = editedProfileName
        self.sourceProfileName = sourceName
        self.defaultClientProvider = defaultClient
        self.serverProfile = profile
        self.transfer = transfer
        self.compareProfile = profiles.first(where: { $0.name != sourceName })?.name ?? ""
        self.source = ConfigEditorHarness.makeState(
            for: sourceName,
            defaultClient: defaultClient,
            serverProfile: profile,
            transfer: transfer
        )
    }

    private static func makeState(
        for name: String,
        defaultClient: @escaping @MainActor () -> DashboardClient?,
        serverProfile: ServerProfile,
        transfer: RemoteSnapshotTransfer?
    ) -> ConfigEditingState {
        ConfigEditingState(
            profileName: name,
            defaultClient: defaultClient,
            serverProfile: serverProfile,
            transfer: transfer
        )
    }

    private func makeState(for name: String) -> ConfigEditingState {
        ConfigEditorHarness.makeState(
            for: name,
            defaultClient: defaultClientProvider,
            serverProfile: serverProfile,
            transfer: transfer
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
        compareProfile = newProfiles.first(where: { $0.name != sourceProfileName })?.name ?? ""
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

    /// Awaits in-flight load/compare chains and cancels both editing states. The
    /// editor borrows the window's dashboard, so there's no process to release.
    func teardown() async {
        compareTask?.cancel()
        await compareTask?.value
        await source.teardown()
        await dest?.teardown()
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
            if compareProfile.isEmpty || compareProfile == sourceProfileName {
                compareProfile = profiles.first(where: { $0.name != sourceProfileName })?.name ?? ""
            }
            guard !compareProfile.isEmpty else { return }
            buildDest(for: compareProfile)
        }
    }

    func setCompareProfile(_ name: String) {
        guard name != compareProfile, name != sourceProfileName else { return }
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
        newDest.banners = banners
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

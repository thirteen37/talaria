import HermesKit
import SwiftUI

/// Errors surfaced by the cross-profile sync section.
enum ProfileSyncError: Error, LocalizedError {
    /// No way to read a profile's `config.yaml` / `.env` (no CLI runner, or a
    /// remote profile with no usable transfer).
    case fileReadUnavailable

    var errorDescription: String? {
        switch self {
        case .fileReadUnavailable:
            return "Can't read this profile's files (no Hermes CLI runner or SSH transfer)."
        }
    }
}

/// A `HermesAdminRunning` that fails every command — used when the window has no
/// base runner, so skills/env reads degrade to per-resource failures (config,
/// which reads files directly, still works).
private struct UnavailableAdminRunner: HermesAdminRunning {
    func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult {
        throw ProfileSyncError.fileReadUnavailable
    }
    func runStream(_ command: HermesAdminCommand) -> AsyncThrowingStream<AdminEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProfileSyncError.fileReadUnavailable) }
    }
}

/// Drives the "Sync from default" surface embedded in the Profiles screen:
/// computes per-profile skills/config/env drift against the default profile
/// (the source of truth) and pushes selected differences. Lazy — the first
/// expand triggers `refresh`. UI-free orchestration delegates to
/// ``ProfileSyncEngine``; this layer owns the SwiftUI-observable state, the
/// scoped-dashboard lifecycle for pushes, and the drift bundles.
@MainActor
@Observable
final class ProfileSyncHarness {
    // MARK: - Loaded drift state

    private(set) var snapshots: [String: ProfileSyncSnapshot] = [:]
    private(set) var skillsDrift: [String: ProfileSkillsDrift] = [:]
    private(set) var configDrift: [String: ProfileConfigDrift] = [:]
    private(set) var envDrift: [String: ProfileEnvDrift] = [:]
    /// Per-profile, per-resource read failures from the last fetch.
    private(set) var resourceErrors: [String: [SyncResource: String]] = [:]
    /// Default-profile resource failures disable the affected section globally.
    private(set) var defaultResourceErrors: [SyncResource: String] = [:]

    /// Set when the catalog index couldn't load — skills *installs* are then
    /// blocked (outdated updates still work).
    private(set) var catalogError: String?
    /// Set when `GET /api/config/schema` failed — config still diffs (curated
    /// prefixes are static), just without schema categories.
    private(set) var schemaError: String?

    var isLoading = false
    private(set) var hasLoaded = false
    /// The curated⇄all toggle for config rows and for the section/profile push
    /// payloads.
    var showAllConfigDifferences = false

    /// Profiles with a profile-level "Sync everything" in flight.
    private(set) var pushingProfiles: Set<String> = []
    /// Per-item push spinners, keyed by ``itemKey(_:profile:id:)``.
    private(set) var pushingItems: Set<String> = []
    /// Per-item outcome errors (nil entry == cleared/success), keyed like
    /// `pushingItems`.
    private(set) var itemErrors: [String: String] = [:]

    /// Bumped on every refresh so revealed env secrets re-mask (mirrors
    /// ``EnvironmentHarness``'s refresh token).
    private(set) var revealToken = 0

    var banners: BannerCenter?

    // MARK: - Dependencies

    private let baseRunner: (any HermesAdminRunning)?
    /// Reads the window's dashboard client live — it may come online after the
    /// Sync tab first appears, so a captured snapshot would stay stale.
    private let windowClientProvider: @MainActor () -> DashboardClient?
    private let catalog: SkillsHubCatalog
    private let hermesVersion: HermesVersion?
    private let acquireScopedClient: @MainActor (String) async throws -> DashboardClient
    private let releaseScopedClient: @MainActor (String) async -> Void
    private let drainScoped: @MainActor () async -> Void
    private let configReader: @Sendable (String) async throws -> JSONValue
    private let envReader: @Sendable (String) async throws -> [EnvFileEntry]

    private let engine = ProfileSyncEngine()
    private var namedProfiles: [String] = []
    /// Catalog index built from the last successful `catalog.skills()`.
    private var index: HubSkillIdentifierIndex?
    private var schema: DashboardConfigSchema?

    init(
        baseRunner: (any HermesAdminRunning)?,
        windowClient: @escaping @MainActor () -> DashboardClient?,
        profile: ServerProfile?,
        snapshotTransfer: RemoteSnapshotTransfer?,
        hermesVersion: HermesVersion?,
        catalog: SkillsHubCatalog = SkillsHubCatalog(),
        acquireScopedClient: @escaping @MainActor (String) async throws -> DashboardClient,
        releaseScopedClient: @escaping @MainActor (String) async -> Void,
        drainScoped: @escaping @MainActor () async -> Void,
        configReader: (@Sendable (String) async throws -> JSONValue)? = nil,
        envReader: (@Sendable (String) async throws -> [EnvFileEntry])? = nil
    ) {
        self.baseRunner = baseRunner
        self.windowClientProvider = windowClient
        self.catalog = catalog
        self.hermesVersion = hermesVersion
        self.acquireScopedClient = acquireScopedClient
        self.releaseScopedClient = releaseScopedClient
        self.drainScoped = drainScoped

        let isLocal = profile?.kind == .local
        let base = baseRunner
        self.configReader = configReader ?? { name in
            guard let profile else { throw ProfileSyncError.fileReadUnavailable }
            let yaml = try await HermesConfigReader.read(profile: profile, profileName: name, transfer: snapshotTransfer)
            return try YAMLConfigCodec.jsonValue(fromYAML: yaml)
        }
        self.envReader = envReader ?? { name in
            guard let base, let profile else { throw ProfileSyncError.fileReadUnavailable }
            let runner = ProfileScopedHermesAdminRunner(inner: base, hermesProfileName: name)
            return try await HermesEnvFileReader(
                runner: runner, snapshotTransfer: snapshotTransfer, isLocal: isLocal, profile: profile
            ).read()
        }
    }

    // MARK: - Capability gating

    /// True when the window can run `hermes` (skills + env-path discovery). Below
    /// this, config still diffs from the file read.
    var hasBaseRunner: Bool { baseRunner != nil }

    /// Capability warning to show, if any (the dashboard / env / skills routes
    /// all share the 0.14.0 pin).
    var capabilityWarning: String? {
        capabilityBanner(.requiresEnvAPI, feature: "Cross-profile sync", version: hermesVersion)
    }

    // MARK: - Refresh

    /// Fetches default + named profiles and recomputes every drift bundle. Lazy:
    /// the view calls this on first expand and on manual refresh.
    func refresh(namedProfiles: [String]) async {
        self.namedProfiles = namedProfiles
        isLoading = true
        defer { isLoading = false }

        // Schema (config categories) — best-effort; config still diffs without it.
        schema = nil
        schemaError = nil
        if let windowClient = windowClientProvider() {
            do {
                schema = try await windowClient.getConfigSchema()
            } catch {
                schemaError = error.localizedDescription
            }
        }

        // Catalog index (skills install identifiers) — best-effort.
        index = nil
        catalogError = nil
        do {
            index = HubSkillIdentifierIndex(catalog: try await catalog.skills())
        } catch {
            catalogError = error.localizedDescription
        }

        let runnerProvider = makeRunnerProvider()
        let result = await engine.fetchSnapshots(
            profiles: ["default"] + namedProfiles,
            runnerProvider: runnerProvider,
            configReader: configReader,
            envReader: envReader
        )
        snapshots = result.snapshots
        resourceErrors = result.failures
        defaultResourceErrors = result.failures["default"] ?? [:]

        recomputeDrift()
        revealToken &+= 1
        hasLoaded = true
    }

    /// Loads a single named profile on demand (the default snapshot + schema +
    /// catalog from the last ``refresh(namedProfiles:)`` are reused), so switching
    /// the picker doesn't re-fetch every profile. A no-op once it's cached.
    func selectProfile(_ name: String) async {
        if snapshots[name] != nil {
            if !namedProfiles.contains(name) {
                namedProfiles.append(name)
                recomputeDrift()
            }
            return
        }
        await refreshProfile(name, addingToNamed: true)
    }

    /// Re-fetches just one profile (plus default stays cached) after a push, so a
    /// successful sync collapses that profile's rows without a full sweep.
    private func refreshProfile(_ name: String, addingToNamed: Bool = false) async {
        if addingToNamed, !namedProfiles.contains(name) {
            namedProfiles.append(name)
        }
        return await refetch(name)
    }

    private func refetch(_ name: String) async {
        let runnerProvider = makeRunnerProvider()
        let result = await engine.fetchSnapshots(
            profiles: [name],
            runnerProvider: runnerProvider,
            configReader: configReader,
            envReader: envReader
        )
        if let snapshot = result.snapshots[name] { snapshots[name] = snapshot }
        if let failures = result.failures[name] {
            resourceErrors[name] = failures
        } else {
            resourceErrors[name] = nil
        }
        recomputeDrift()
        revealToken &+= 1
    }

    private func makeRunnerProvider() -> RunnerProvider {
        if let baseRunner {
            return ProfileSyncEngine.scopedRunnerProvider(base: baseRunner)
        }
        return { _ in UnavailableAdminRunner() }
    }

    private func recomputeDrift() {
        guard let defaultSnapshot = snapshots["default"] else { return }
        var skills: [String: ProfileSkillsDrift] = [:]
        var config: [String: ProfileConfigDrift] = [:]
        var env: [String: ProfileEnvDrift] = [:]
        for name in namedProfiles {
            guard let snapshot = snapshots[name] else { continue }
            skills[name] = ProfileSkillsDriftPlanner.drift(
                profileName: name,
                defaultSkills: defaultSnapshot.skills,
                profileSkills: snapshot.skills,
                updateStatuses: snapshot.updateStatuses,
                index: index
            )
            if let defaultConfig = defaultSnapshot.config, let profileConfig = snapshot.config {
                config[name] = ProfileConfigDriftPlanner.drift(
                    profileName: name, defaultConfig: defaultConfig, profileConfig: profileConfig, schema: schema
                )
            }
            if let defaultEnv = defaultSnapshot.env, let profileEnv = snapshot.env {
                env[name] = ProfileEnvDriftPlanner.drift(
                    profileName: name, defaultEntries: defaultEnv, profileEntries: profileEnv
                )
            }
        }
        skillsDrift = skills
        configDrift = config
        envDrift = env
    }

    // MARK: - Summary

    /// Total out-of-sync items across all named profiles.
    var totalDifferences: Int {
        var total = 0
        for name in namedProfiles {
            total += skillsDrift[name]?.items.count ?? 0
            total += configDrift[name]?.items.count ?? 0
            total += envDrift[name]?.items.count ?? 0
        }
        return total
    }

    /// Named profiles that have at least one difference.
    var profilesWithDrift: Int {
        namedProfiles.filter { differenceCount(for: $0) > 0 }.count
    }

    func differenceCount(for profile: String) -> Int {
        (skillsDrift[profile]?.items.count ?? 0)
            + (configDrift[profile]?.items.count ?? 0)
            + (envDrift[profile]?.items.count ?? 0)
    }

    var allInSync: Bool { totalDifferences == 0 }

    // MARK: - Push: skills

    func syncSkill(_ item: SkillDriftItem, profile: String) async {
        guard let action = skillAction(for: item) else { return }
        await runItemPush(profile: profile, resource: "skill", id: item.id) {
            let outcomes = await self.engine.pushSkills(
                actions: [action], toProfile: profile, runnerProvider: self.makeRunnerProvider()
            )
            return outcomes.first?.error
        }
        await refreshProfile(profile)
    }

    func syncAllSkills(profile: String) async {
        let actions = (skillsDrift[profile]?.items ?? []).compactMap(skillAction(for:))
        guard !actions.isEmpty else { return }
        pushingProfiles.insert(profile)
        defer { pushingProfiles.remove(profile) }
        _ = await engine.pushSkills(actions: actions, toProfile: profile, runnerProvider: makeRunnerProvider())
        await refreshProfile(profile)
    }

    private func skillAction(for item: SkillDriftItem) -> SkillPushAction? {
        switch item.kind {
        case let .missing(identifier, _):
            guard let identifier else { return nil }
            return .install(identifier: identifier, name: item.name)
        case .outdated:
            return .update(name: item.name)
        }
    }

    // MARK: - Push: config

    func syncConfigItem(_ item: ConfigDriftItem, profile: String) async {
        guard item.isPushable, let drift = configDrift[profile] else { return }
        let edits = drift.pushPayload(dotpaths: [item.dotpath])
        guard !edits.isEmpty else { return }
        await runItemPush(profile: profile, resource: "config", id: item.dotpath) {
            await self.pushConfigEdits(edits, profile: profile)
        }
        await refreshProfile(profile)
    }

    func syncAllConfig(profile: String, curatedOnly: Bool) async {
        guard let drift = configDrift[profile] else { return }
        let edits = drift.pushPayload(curatedOnly: curatedOnly)
        guard !edits.isEmpty else { return }
        pushingProfiles.insert(profile)
        defer { pushingProfiles.remove(profile) }
        _ = await pushConfigEdits(edits, profile: profile)
        await refreshProfile(profile)
    }

    /// Acquires the profile's scoped dashboard, pushes the edits, releases.
    /// Returns an error string on failure, nil on success.
    private func pushConfigEdits(_ edits: [String: ConfigValue], profile: String) async -> String? {
        do {
            let client = try await acquireScopedClient(profile)
            let outcome = await engine.pushConfig(edits: edits, client: client)
            await releaseScopedClient(profile)
            return outcome.error
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Push: env

    func syncEnvItem(_ item: EnvDriftItem, profile: String) async {
        guard let value = plaintext(forKey: item.key) else { return }
        await runItemPush(profile: profile, resource: "env", id: item.key) {
            await self.pushEnvItems([(key: item.key, value: value)], profile: profile).first ?? nil
        }
        await refreshProfile(profile)
    }

    func syncAllEnv(profile: String) async {
        let items = envPushItems(for: profile)
        guard !items.isEmpty else { return }
        pushingProfiles.insert(profile)
        defer { pushingProfiles.remove(profile) }
        _ = await pushEnvItems(items, profile: profile)
        await refreshProfile(profile)
    }

    /// Acquires the profile's scoped dashboard, pushes each key, releases.
    /// Returns the per-key error strings (nil == success).
    private func pushEnvItems(_ items: [(key: String, value: String)], profile: String) async -> [String?] {
        do {
            let client = try await acquireScopedClient(profile)
            let outcomes = await engine.pushEnv(items: items, client: client)
            await releaseScopedClient(profile)
            return outcomes.map(\.error)
        } catch {
            return items.map { _ in error.localizedDescription }
        }
    }

    /// The default profile's plaintext for `key` (from the in-memory snapshot;
    /// never an API call).
    func plaintext(forKey key: String) -> String? {
        plaintext(forKey: key, inProfile: HermesProfiles.defaultProfileName)
    }

    /// A specific profile's plaintext for `key` (from the in-memory snapshot;
    /// never an API call) — used to reveal either column of the env comparison.
    func plaintext(forKey key: String, inProfile profile: String) -> String? {
        snapshots[profile]?.env?.first { $0.key == key }?.value
    }

    private func envPushItems(for profile: String) -> [(key: String, value: String)] {
        (envDrift[profile]?.items ?? []).compactMap { item in
            guard let value = plaintext(forKey: item.key) else { return nil }
            return (key: item.key, value: value)
        }
    }

    // MARK: - Push: everything

    /// Profile-level "Sync everything from default" — skills via CLI, then config
    /// and env over a single scoped-dashboard acquisition, then re-snapshot.
    /// Honors the curated⇄all toggle for the config payload.
    func syncEverything(profile: String) async {
        pushingProfiles.insert(profile)
        defer { pushingProfiles.remove(profile) }

        let actions = (skillsDrift[profile]?.items ?? []).compactMap(skillAction(for:))
        if !actions.isEmpty {
            _ = await engine.pushSkills(actions: actions, toProfile: profile, runnerProvider: makeRunnerProvider())
        }

        let configEdits = configDrift[profile]?.pushPayload(curatedOnly: !showAllConfigDifferences) ?? [:]
        let envItems = envPushItems(for: profile)
        if !configEdits.isEmpty || !envItems.isEmpty {
            do {
                let client = try await acquireScopedClient(profile)
                if !configEdits.isEmpty {
                    let outcome = await engine.pushConfig(edits: configEdits, client: client)
                    if let error = outcome.error { banners?.surfaceError("profiles", error) }
                }
                if !envItems.isEmpty {
                    _ = await engine.pushEnv(items: envItems, client: client)
                }
                await releaseScopedClient(profile)
            } catch {
                banners?.surfaceError("profiles", error.localizedDescription)
            }
        }

        await refreshProfile(profile)
    }

    /// A human summary of what "Sync everything" will do, for the confirmation
    /// sheet (it writes secrets, so the batch confirms first).
    func syncEverythingSummary(for profile: String) -> String {
        var parts: [String] = []
        let skills = skillsDrift[profile]?.items.compactMap(skillAction(for:)) ?? []
        let installs = skills.filter { if case .install = $0 { return true } else { return false } }.count
        let updates = skills.count - installs
        if installs > 0 { parts.append("install \(installs) skill\(installs == 1 ? "" : "s")") }
        if updates > 0 { parts.append("update \(updates) skill\(updates == 1 ? "" : "s")") }
        let configCount = configDrift[profile]?.pushPayload(curatedOnly: !showAllConfigDifferences).count ?? 0
        if configCount > 0 { parts.append("push \(configCount) config value\(configCount == 1 ? "" : "s")") }
        let envCount = envPushItems(for: profile).count
        if envCount > 0 { parts.append("copy \(envCount) credential\(envCount == 1 ? "" : "s")") }
        guard !parts.isEmpty else { return "Nothing to sync to “\(profile)”." }
        return "This will \(parts.joined(separator: ", ")) to “\(profile)”."
    }

    func canSyncEverything(profile: String) -> Bool { differenceCount(for: profile) > 0 }

    // MARK: - Teardown

    func teardown() async {
        await drainScoped()
    }

    // MARK: - Item bookkeeping

    func itemKey(_ resource: String, profile: String, id: String) -> String {
        "\(profile)|\(resource)|\(id)"
    }

    func isPushingItem(_ resource: String, profile: String, id: String) -> Bool {
        pushingItems.contains(itemKey(resource, profile: profile, id: id))
    }

    func itemError(_ resource: String, profile: String, id: String) -> String? {
        itemErrors[itemKey(resource, profile: profile, id: id)]
    }

    private func runItemPush(
        profile: String,
        resource: String,
        id: String,
        _ work: @escaping () async -> String?
    ) async {
        let key = itemKey(resource, profile: profile, id: id)
        pushingItems.insert(key)
        itemErrors[key] = nil
        defer { pushingItems.remove(key) }
        if let error = await work() {
            itemErrors[key] = error
        }
    }
}

// MARK: - View

/// The "Sync from default" surface — a dedicated tab in the Profiles
/// destination. Default profile is the source of truth; each named profile gets
/// a row that expands into skills / config / environment subsections. Shared
/// layout (no platform seam) — stacked rows fit the macOS detail column, iPad,
/// and the iPhone Browse sheet.
///
/// Self-contained: it enumerates the server's named profiles from the dashboard
/// (`GET /api/profiles`) rather than depending on the table tab's state, then
/// lazily computes drift on first appearance.
struct ProfileSyncView: View {
    let baseRunner: (any HermesAdminRunning)?
    /// Live window dashboard client — it may come online after this tab opens, so
    /// it's read through a provider rather than captured.
    let windowClient: @MainActor () -> DashboardClient?
    let profile: ServerProfile?
    let snapshotTransfer: RemoteSnapshotTransfer?
    let hermesVersion: HermesVersion?
    /// The window's active Hermes profile — decides which side of the config
    /// comparison may read the window's shared client.
    let activeProfile: String
    let acquireScoped: @MainActor (String) async throws -> (DashboardSupervisor, DashboardClient)
    let releaseScoped: @MainActor (DashboardSupervisor) async -> Void

    @Environment(BannerCenter.self) private var banners: BannerCenter?

    @State private var harness: ProfileSyncHarness?
    @State private var pool: ScopedDashboardPool<DashboardSupervisor, DashboardClient>?
    /// Config comparison reuses the config editor's two-column view, source pinned
    /// to `default`. Desktop/iPad only (nil on iPhone, where Compare can't render).
    @State private var configEditor: ConfigEditorHarness?
    @State private var allProfiles: [HermesProfileInfo] = []
    @State private var namedProfiles: [String] = []
    @State private var selectedProfile: String?
    @State private var section: SyncSection = .skills
    @State private var configLoaded = false
    @State private var confirmingProfile: String?

    private enum SyncSection: String, CaseIterable, Identifiable {
        case skills = "Skills"
        case config = "Config"
        case environment = "Environment"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if windowClient() == nil {
                ContentUnavailableView(
                    "Dashboard not ready",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("Waiting for the Hermes dashboard to come online.")
                )
            } else if let harness {
                content(harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Sync from default")
        .dismissesBanner("profiles", from: banners)
        .toolbar {
            if let harness {
                ToolbarItem {
                    Button { Task { await reload(harness) } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(harness.isLoading)
                    .help("Re-read every profile and recompute differences")
                }
            }
        }
        // Lazy: the first time this tab appears, build the harness and compute
        // drift. Re-selecting the tab reuses the loaded state (Refresh re-reads).
        .task {
            let harness = ensureHarness()
            guard !harness.hasLoaded, !harness.isLoading else { return }
            await reload(harness)
        }
        .onDisappear {
            let h = harness
            let editor = configEditor
            Task { await h?.teardown(); await editor?.teardown() }
        }
    }

    /// Builds (once) and returns the harness, so the initial `.task` can use it
    /// immediately without waiting for the `@State` write to land. Also builds the
    /// config comparison harness (its dashboards spawn only when Config is opened).
    private func ensureHarness() -> ProfileSyncHarness {
        if let harness { return harness }
        let pool = ScopedDashboardPool<DashboardSupervisor, DashboardClient>(
            acquire: acquireScoped,
            release: releaseScoped
        )
        self.pool = pool
        let provider = windowClient
        let h = ProfileSyncHarness(
            baseRunner: baseRunner,
            windowClient: provider,
            profile: profile,
            snapshotTransfer: snapshotTransfer,
            hermesVersion: hermesVersion,
            acquireScopedClient: { try await pool.acquire($0) },
            releaseScopedClient: { await pool.release($0) },
            drainScoped: { await pool.drain() }
        )
        h.banners = banners
        harness = h
        if let profile, !Idiom.isPhone {
            let editor = ConfigEditorHarness(
                profiles: allProfiles,
                editedProfileName: activeProfile,
                sourceProfileName: HermesProfiles.defaultProfileName,
                defaultClient: provider,
                profile: profile,
                transfer: snapshotTransfer,
                acquireScoped: acquireScoped,
                releaseScoped: releaseScoped
            )
            editor.banners = banners
            configEditor = editor
        }
        return h
    }

    /// Re-enumerates the server's named profiles (cheap — one `/api/profiles`),
    /// then computes drift for **only** the selected profile on desktop/iPad (the
    /// per-profile reads — skills `check`, config + `.env` — are the slow part, so
    /// the unselected profiles are loaded lazily on demand). iPhone's stacked list
    /// shows every profile, so it still loads them all.
    private func reload(_ harness: ProfileSyncHarness) async {
        let profiles = await HermesProfiles.selectorProfiles(client: windowClient())
        allProfiles = profiles
        namedProfiles = profiles
            .filter { !$0.isDefault && $0.name != HermesProfiles.defaultProfileName }
            .map(\.name)
        if selectedProfile == nil || !namedProfiles.contains(selectedProfile ?? "") {
            selectedProfile = namedProfiles.first
        }
        configEditor?.setAvailableProfiles(profiles)
        let toLoad = Idiom.isPhone ? namedProfiles : selectedProfile.map { [$0] } ?? []
        await harness.refresh(namedProfiles: toLoad)
        if section == .config { activateConfigComparison() }
    }

    /// Loads the config comparison's source (default) once and points its dest at
    /// the selected profile — so dashboards spawn only when Config is opened.
    private func activateConfigComparison() {
        guard let editor = configEditor, let selected = selectedProfile else { return }
        if !configLoaded {
            configLoaded = true
            Task { await editor.start() }
        }
        if editor.compareProfile != selected {
            editor.setCompareProfile(selected)
        } else if !editor.comparing {
            editor.toggleComparing()
        }
    }

    @ViewBuilder
    private func content(_ harness: ProfileSyncHarness) -> some View {
        VStack(spacing: 0) {
            if let warning = harness.capabilityWarning {
                ManageBanner(severity: .warning, message: warning)
            }
            if !harness.hasBaseRunner {
                ManageBanner(severity: .warning, message: "Hermes CLI unavailable for this window — skills and credentials can't be synced.")
            }

            if harness.isLoading, !harness.hasLoaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if namedProfiles.isEmpty {
                ContentUnavailableView(
                    "No named profiles",
                    systemImage: "square.stack.3d.up",
                    description: Text("Clone the default profile on the Profiles tab to create one to sync to.")
                )
            } else if Idiom.isPhone {
                phoneList(harness)
            } else {
                desktopComparison(harness)
            }
        }
        .confirmationDialog(
            "Sync everything from default?",
            isPresented: Binding(
                get: { confirmingProfile != nil },
                set: { if !$0 { confirmingProfile = nil } }
            ),
            presenting: confirmingProfile
        ) { name in
            Button("Sync everything") {
                Task {
                    await harness.syncEverything(profile: name)
                    await configEditor?.refresh()
                }
                confirmingProfile = nil
            }
            Button("Cancel", role: .cancel) { confirmingProfile = nil }
        } message: { name in
            Text(harness.syncEverythingSummary(for: name))
        }
    }

    // MARK: - Desktop / iPad: picker + segmented comparison

    @ViewBuilder
    private func desktopComparison(_ harness: ProfileSyncHarness) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Profile", selection: $selectedProfile) {
                    ForEach(namedProfiles, id: \.self) { Text($0).tag($0 as String?) }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                Spacer()
                if let selected = selectedProfile {
                    if harness.pushingProfiles.contains(selected) {
                        ProgressView().controlSize(.small)
                    }
                    // Skills carries its own "Sync all" in its list; Config and
                    // Environment get one here, pushing every difference at once.
                    if section != .skills, sectionCount(section, profile: selected, harness: harness) > 0 {
                        Button("Sync all") { syncAllForSection(selected, harness: harness) }
                            .help("Push every \(section.rawValue.lowercased()) difference from default to “\(selected)”")
                            .accessibilityLabel("Sync all \(section.rawValue.lowercased()) from default to \(selected)")
                    }
                    Button("Sync everything from default") { confirmingProfile = selected }
                        .help("Install/update skills and copy config + credentials from default to “\(selected)”")
                        .accessibilityLabel("Sync everything from default to \(selected)")
                }
            }
            .padding()

            if let selected = selectedProfile {
                Picker("Section", selection: $section) {
                    ForEach(SyncSection.allCases) { section in
                        Text(sectionLabel(section, profile: selected, harness: harness)).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal)
                .padding(.bottom, 8)

                Divider()
                sectionContent(selected, harness: harness)
            }
        }
        // Switching the picker lazily loads that profile's drift (default + the
        // earlier profiles stay cached).
        .onChange(of: selectedProfile) { _, newValue in
            guard harness.hasLoaded, let newValue else { return }
            Task {
                await harness.selectProfile(newValue)
                if section == .config { activateConfigComparison() }
            }
        }
        .onChange(of: section) { _, _ in if section == .config { activateConfigComparison() } }
    }

    private func sectionCount(_ section: SyncSection, profile: String, harness: ProfileSyncHarness) -> Int {
        switch section {
        case .skills: return harness.skillsDrift[profile]?.items.count ?? 0
        case .config: return harness.configDrift[profile]?.items.count ?? 0
        case .environment: return harness.envDrift[profile]?.items.count ?? 0
        }
    }

    private func sectionLabel(_ section: SyncSection, profile: String, harness: ProfileSyncHarness) -> String {
        let count = sectionCount(section, profile: profile, harness: harness)
        return count > 0 ? "\(section.rawValue) (\(count))" : section.rawValue
    }

    private func syncAllForSection(_ selected: String, harness: ProfileSyncHarness) {
        switch section {
        case .skills:
            Task { await harness.syncAllSkills(profile: selected) }
        case .config:
            Task {
                await harness.syncAllConfig(profile: selected, curatedOnly: false)
                await configEditor?.refresh()
            }
        case .environment:
            Task { await harness.syncAllEnv(profile: selected) }
        }
    }

    @ViewBuilder
    private func sectionContent(_ selected: String, harness: ProfileSyncHarness) -> some View {
        switch section {
        case .skills:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    SkillsSubsection(harness: harness, profile: selected)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .config:
            configComparison(selected)
        case .environment:
            EnvComparisonView(harness: harness, profile: selected)
        }
    }

    @ViewBuilder
    private func configComparison(_ selected: String) -> some View {
        if let editor = configEditor {
            if let dest = editor.dest, dest.profileName == selected {
                EditableComparisonView(
                    source: editor.source,
                    dest: dest,
                    showDifferencesOnly: true,
                    immediateCopy: true,
                    allowReverseCopy: false
                )
            } else {
                ProgressView("Loading config…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView(
                "Config comparison unavailable",
                systemImage: "rectangle.on.rectangle.slash",
                description: Text("This window can't open a config dashboard for these profiles.")
            )
        }
    }

    // MARK: - iPhone: stacked read-only-ish list

    @ViewBuilder
    private func phoneList(_ harness: ProfileSyncHarness) -> some View {
        @Bindable var harness = harness
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show all config differences", isOn: $harness.showAllConfigDifferences)
                    .font(.caption)
                    .help("Reveal config rows outside the curated provider/model sections")
                ForEach(namedProfiles, id: \.self) { name in
                    ProfileDriftRow(harness: harness, profile: name, confirmingProfile: $confirmingProfile)
                    Divider()
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Environment comparison (two-column, redacted)

/// Two-column environment comparison styled like the config comparison: each row
/// is a key with the **default**'s redacted value, a one-way copy gutter, and the
/// **profile**'s redacted value. Reveal is local (the plaintext is already in the
/// snapshot); copy-→ pushes default's secret immediately via the scoped dashboard.
private struct EnvComparisonView: View {
    let harness: ProfileSyncHarness
    let profile: String

    var body: some View {
        let drift = harness.envDrift[profile]
        let error = harness.resourceErrors[profile]?[.env] ?? harness.defaultResourceErrors[.env]
        VStack(spacing: 0) {
            header
            Divider()
            if let error {
                ManageBanner(severity: .warning, message: error)
                Spacer()
            } else if let drift {
                if drift.items.isEmpty, drift.extras.isEmpty {
                    ContentUnavailableView(
                        "Environment in sync",
                        systemImage: "equal.circle",
                        description: Text("Every credential matches the default profile.")
                    )
                } else {
                    List {
                        if !drift.items.isEmpty {
                            Section("Differences") {
                                ForEach(drift.items) { row($0) }
                            }
                        }
                        if !drift.extras.isEmpty {
                            Section("Only in “\(profile)” (not removed)") {
                                ForEach(drift.extras) { extra in
                                    Text(extra.key).font(.system(.caption, design: .monospaced))
                                }
                            }
                        }
                    }
                    #if os(macOS)
                    .listStyle(.inset)
                    #else
                    .listStyle(.insetGrouped)
                    #endif
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(HermesProfiles.defaultProfileName).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 36, height: 0)
            Text(profile).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder
    private func row(_ item: EnvDriftItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.key)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
            HStack(alignment: .top, spacing: 8) {
                EnvValueCell(
                    redacted: item.redactedDefaultValue,
                    plaintext: { harness.plaintext(forKey: item.key) },
                    remaskToken: harness.revealToken
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                copyGutter(item)
                // A missing key (no value) and a present-but-empty value both
                // render as "—" so the column reads consistently.
                EnvValueCell(
                    redacted: item.redactedProfileValue ?? "",
                    plaintext: { harness.plaintext(forKey: item.key, inProfile: profile) },
                    remaskToken: harness.revealToken
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = harness.itemError("env", profile: profile, id: item.key) {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func copyGutter(_ item: EnvDriftItem) -> some View {
        VStack {
            if harness.isPushingItem("env", profile: profile, id: item.key) {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await harness.syncEnvItem(item, profile: profile) }
                } label: {
                    Image(systemName: "arrow.right")
                }
                .buttonStyle(.borderless)
                .imageScale(.small)
                .help("Copy default's “\(item.key)” secret to “\(profile)” (saves immediately)")
            }
        }
        .frame(width: 36)
    }
}

/// One redacted env value with a local reveal toggle. The plaintext is already in
/// memory (the snapshot), so reveal is a no-op API-wise; it re-masks on collapse
/// and on the harness's `revealToken` bump.
private struct EnvValueCell: View {
    let redacted: String
    let plaintext: () -> String?
    let remaskToken: Int

    @State private var revealed = false

    var body: some View {
        HStack(spacing: 4) {
            if redacted.isEmpty {
                // Missing key, or a present-but-empty value — render the same so
                // the column reads consistently.
                Text("—").foregroundStyle(.secondary)
            } else {
                Text(revealed ? (plaintext() ?? redacted) : redacted)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel(revealed ? "Hide value" : "Show value")
                .help(revealed ? "Hide the value" : "Reveal the value")
            }
        }
        .onChange(of: remaskToken) { _, _ in revealed = false }
        .onDisappear { revealed = false }
    }
}

// MARK: - Per-profile row

private struct ProfileDriftRow: View {
    let harness: ProfileSyncHarness
    let profile: String
    @Binding var confirmingProfile: String?

    @State private var expanded = false

    private var count: Int { harness.differenceCount(for: profile) }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                SkillsSubsection(harness: harness, profile: profile)
                ConfigSubsection(harness: harness, profile: profile)
                EnvSubsection(harness: harness, profile: profile)
            }
            .padding(.vertical, 6)
        } label: {
            HStack(spacing: 8) {
                Text(profile).font(.body.weight(.medium))
                statusPill
                Spacer()
                if harness.pushingProfiles.contains(profile) {
                    ProgressView().controlSize(.small)
                } else if count > 0 {
                    Button("Sync everything") { confirmingProfile = profile }
                        .controlSize(.small)
                        .help("Install/update skills and copy config + credentials from default to “\(profile)”")
                        .accessibilityLabel("Sync everything from default to \(profile)")
                }
            }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        if count == 0 {
            Label("In sync", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        } else {
            Text(driftSummary).font(.caption2).foregroundStyle(.orange)
        }
    }

    private var driftSummary: String {
        var parts: [String] = []
        let s = harness.skillsDrift[profile]?.items.count ?? 0
        let c = harness.configDrift[profile]?.items.count ?? 0
        let e = harness.envDrift[profile]?.items.count ?? 0
        if s > 0 { parts.append("\(s) skill\(s == 1 ? "" : "s")") }
        if c > 0 { parts.append("\(c) config") }
        if e > 0 { parts.append("\(e) env") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Skills subsection

private struct SkillsSubsection: View {
    let harness: ProfileSyncHarness
    let profile: String

    var body: some View {
        let drift = harness.skillsDrift[profile]
        VStack(alignment: .leading, spacing: 6) {
            subsectionHeader(
                title: "Skills",
                inSync: drift?.isInSync ?? true,
                error: harness.resourceErrors[profile]?[.skills] ?? harness.defaultResourceErrors[.skills],
                showSyncAll: (drift?.items.contains { $0.isActionable }) ?? false,
                syncAll: { Task { await harness.syncAllSkills(profile: profile) } }
            )
            if let drift, !drift.isInSync {
                ForEach(drift.items) { item in
                    skillRow(item)
                }
                if !drift.extras.isEmpty {
                    Text("\(drift.extras.count) skill\(drift.extras.count == 1 ? "" : "s") only in “\(profile)” (not removed).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func skillRow(_ item: SkillDriftItem) -> some View {
        HStack(spacing: 8) {
            kindBadge(item)
            Text(item.name).font(.caption)
            Spacer()
            if harness.isPushingItem("skill", profile: profile, id: item.id) {
                ProgressView().controlSize(.small)
            } else if item.isActionable {
                Button(actionLabel(item)) { Task { await harness.syncSkill(item, profile: profile) } }
                    .controlSize(.small)
                    .help("\(actionLabel(item)) “\(item.name)” in “\(profile)”")
            } else {
                Text(blockedCaption(item)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        if let error = harness.itemError("skill", profile: profile, id: item.id) {
            Text(error).font(.caption2).foregroundStyle(.red)
        }
    }

    private func kindBadge(_ item: SkillDriftItem) -> some View {
        let text: String
        switch item.kind {
        case .missing: text = "missing"
        case .outdated: text = "outdated"
        }
        return Text(text)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.orange.opacity(0.15), in: Capsule())
    }

    private func actionLabel(_ item: SkillDriftItem) -> String {
        if case .outdated = item.kind { return "Update" }
        return "Install"
    }

    private func blockedCaption(_ item: SkillDriftItem) -> String {
        if case let .missing(_, blocker) = item.kind {
            switch blocker {
            case .identifierNotFound: return "Not in the Skills Hub catalog — install manually"
            case .catalogUnavailable: return "Catalog unavailable"
            case .none: return ""
            }
        }
        return ""
    }
}

// MARK: - Config subsection

private struct ConfigSubsection: View {
    let harness: ProfileSyncHarness
    let profile: String

    var body: some View {
        let drift = harness.configDrift[profile]
        let rows = visibleRows(drift)
        VStack(alignment: .leading, spacing: 6) {
            subsectionHeader(
                title: "Config",
                inSync: rows.isEmpty,
                error: harness.resourceErrors[profile]?[.config] ?? harness.defaultResourceErrors[.config],
                showSyncAll: rows.contains { $0.isPushable },
                syncAll: { Task { await harness.syncAllConfig(profile: profile, curatedOnly: !harness.showAllConfigDifferences) } }
            )
            if harness.schemaError != nil {
                Text("Config schema unavailable — showing differences without category grouping.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(rows) { item in
                configRow(item)
            }
            if let extras = drift?.extras, !extras.isEmpty {
                Text("\(extras.count) config key\(extras.count == 1 ? "" : "s") only in “\(profile)” (not removed).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func visibleRows(_ drift: ProfileConfigDrift?) -> [ConfigDriftItem] {
        guard let drift else { return [] }
        return harness.showAllConfigDifferences ? drift.items : drift.curatedItems
    }

    @ViewBuilder
    private func configRow(_ item: ConfigDriftItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.dotpath).font(.caption.monospaced())
                Text("\(valueText(item.defaultValue)) → \(item.profileValue.map(valueText) ?? "—")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if harness.isPushingItem("config", profile: profile, id: item.dotpath) {
                ProgressView().controlSize(.small)
            } else if item.isPushable {
                Button("Push") { Task { await harness.syncConfigItem(item, profile: profile) } }
                    .controlSize(.small)
                    .help("Copy default's “\(item.dotpath)” to “\(profile)”")
            } else {
                Text("read-only").font(.caption2).foregroundStyle(.secondary)
            }
        }
        if let error = harness.itemError("config", profile: profile, id: item.dotpath) {
            Text(error).font(.caption2).foregroundStyle(.red)
        }
    }

    private func valueText(_ value: ConfigValue) -> String {
        switch value {
        case let .string(s): return s.isEmpty ? "\"\"" : s
        case let .number(n): return n == n.rounded() ? String(Int(n)) : String(n)
        case let .bool(b): return b ? "true" : "false"
        case let .list(items): return "[\(items.joined(separator: ", "))]"
        case .missing: return "—"
        case .raw: return "(complex)"
        }
    }
}

// MARK: - Environment subsection

private struct EnvSubsection: View {
    let harness: ProfileSyncHarness
    let profile: String

    var body: some View {
        let drift = harness.envDrift[profile]
        VStack(alignment: .leading, spacing: 6) {
            subsectionHeader(
                title: "Environment",
                inSync: drift?.isInSync ?? true,
                error: harness.resourceErrors[profile]?[.env] ?? harness.defaultResourceErrors[.env],
                showSyncAll: (drift?.items.isEmpty == false),
                syncAll: { Task { await harness.syncAllEnv(profile: profile) } }
            )
            if let drift, !drift.isInSync {
                ForEach(drift.items) { item in
                    envRow(item)
                }
                if !drift.extras.isEmpty {
                    Text("\(drift.extras.count) key\(drift.extras.count == 1 ? "" : "s") only in “\(profile)” (not removed).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func envRow(_ item: EnvDriftItem) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.key).font(.caption.monospaced())
                RevealableEnvValue(
                    redactedDefault: item.redactedDefaultValue,
                    redactedProfile: item.redactedProfileValue,
                    plaintext: { harness.plaintext(forKey: item.key) },
                    remaskToken: harness.revealToken
                )
            }
            Spacer()
            if harness.isPushingItem("env", profile: profile, id: item.key) {
                ProgressView().controlSize(.small)
            } else {
                Button(item.kind == .missing ? "Copy" : "Update") {
                    Task { await harness.syncEnvItem(item, profile: profile) }
                }
                .controlSize(.small)
                .help("Copy default's “\(item.key)” secret to “\(profile)”")
            }
        }
        if let error = harness.itemError("env", profile: profile, id: item.key) {
            Text(error).font(.caption2).foregroundStyle(.red)
        }
    }
}

/// A redacted env value with a local reveal (the plaintext is already in memory;
/// no rate-limited API call). Re-masks on collapse and on the harness's
/// `revealToken` bump.
private struct RevealableEnvValue: View {
    let redactedDefault: String
    let redactedProfile: String?
    let plaintext: () -> String?
    let remaskToken: Int

    @State private var revealed = false

    var body: some View {
        HStack(spacing: 4) {
            Text(displayText).font(.caption2.monospaced()).foregroundStyle(.secondary)
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel(revealed ? "Hide value" : "Show value")
            .help(revealed ? "Hide the value" : "Reveal default's value")
        }
        .onChange(of: remaskToken) { _, _ in revealed = false }
        .onDisappear { revealed = false }
    }

    private var displayText: String {
        let defaultPart = revealed ? (plaintext() ?? redactedDefault) : redactedDefault
        if let redactedProfile {
            return "\(redactedProfile) → \(defaultPart)"
        }
        return "— → \(defaultPart)"
    }
}

// MARK: - Shared subsection header

@MainActor @ViewBuilder
private func subsectionHeader(
    title: String,
    inSync: Bool,
    error: String?,
    showSyncAll: Bool,
    syncAll: @escaping () -> Void
) -> some View {
    HStack(spacing: 6) {
        Text(title).font(.subheadline.weight(.semibold))
        if let error {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption2)
            Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(1)
        } else if inSync {
            Image(systemName: "checkmark").font(.caption2).foregroundStyle(.green)
        }
        Spacer()
        if showSyncAll {
            Button("Sync all") { syncAll() }
                .controlSize(.small)
                .help("Push every \(title.lowercased()) difference from default")
        }
    }
}

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
    private let windowClient: DashboardClient?
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
        windowClient: DashboardClient?,
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
        self.windowClient = windowClient
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
        if let windowClient {
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

    /// Re-fetches just one profile (plus default stays cached) after a push, so a
    /// successful sync collapses that profile's rows without a full sweep.
    private func refreshProfile(_ name: String) async {
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

    func syncAllConfig(profile: String) async {
        guard let drift = configDrift[profile] else { return }
        let edits = drift.pushPayload(curatedOnly: !showAllConfigDifferences)
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
        snapshots["default"]?.env?.first { $0.key == key }?.value
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
    let windowClient: DashboardClient?
    let profile: ServerProfile?
    let snapshotTransfer: RemoteSnapshotTransfer?
    let hermesVersion: HermesVersion?
    let acquireScoped: @MainActor (String) async throws -> (DashboardSupervisor, DashboardClient)
    let releaseScoped: @MainActor (DashboardSupervisor) async -> Void

    @Environment(BannerCenter.self) private var banners: BannerCenter?

    @State private var harness: ProfileSyncHarness?
    @State private var pool: ScopedDashboardPool<DashboardSupervisor, DashboardClient>?
    @State private var namedProfiles: [String] = []
    @State private var confirmingProfile: String?

    var body: some View {
        Group {
            if windowClient == nil {
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
            Task { await h?.teardown() }
        }
    }

    /// Builds (once) and returns the harness, so the initial `.task` can use it
    /// immediately without waiting for the `@State` write to land.
    private func ensureHarness() -> ProfileSyncHarness {
        if let harness { return harness }
        let pool = ScopedDashboardPool<DashboardSupervisor, DashboardClient>(
            acquire: acquireScoped,
            release: releaseScoped
        )
        self.pool = pool
        let h = ProfileSyncHarness(
            baseRunner: baseRunner,
            windowClient: windowClient,
            profile: profile,
            snapshotTransfer: snapshotTransfer,
            hermesVersion: hermesVersion,
            acquireScopedClient: { try await pool.acquire($0) },
            releaseScopedClient: { await pool.release($0) },
            drainScoped: { await pool.drain() }
        )
        h.banners = banners
        harness = h
        return h
    }

    /// Re-enumerates the server's named profiles, then recomputes drift. A
    /// just-cloned profile thus appears without leaving the tab.
    private func reload(_ harness: ProfileSyncHarness) async {
        let profiles = await HermesProfiles.selectorProfiles(client: windowClient)
        namedProfiles = profiles
            .filter { !$0.isDefault && $0.name != HermesProfiles.defaultProfileName }
            .map(\.name)
        await harness.refresh(namedProfiles: namedProfiles)
    }

    @ViewBuilder
    private func content(_ harness: ProfileSyncHarness) -> some View {
        @Bindable var harness = harness
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header(harness)

                if let warning = harness.capabilityWarning {
                    ManageBanner(severity: .warning, message: warning)
                }
                if !harness.hasBaseRunner {
                    ManageBanner(severity: .warning, message: "Hermes CLI unavailable for this window — skills and credentials can't be synced.")
                }

                if harness.isLoading, !harness.hasLoaded {
                    ProgressView().frame(maxWidth: .infinity)
                } else if namedProfiles.isEmpty {
                    ContentUnavailableView(
                        "No named profiles",
                        systemImage: "square.stack.3d.up",
                        description: Text("Clone the default profile on the Profiles tab to create one to sync to.")
                    )
                } else {
                    Toggle("Show all config differences", isOn: $harness.showAllConfigDifferences)
                        .font(.caption)
                        .toggleStyle(.checkbox)
                        .help("Reveal config rows outside the curated provider/model sections")

                    ForEach(namedProfiles, id: \.self) { name in
                        ProfileDriftRow(harness: harness, profile: name, confirmingProfile: $confirmingProfile)
                        Divider()
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
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
                Task { await harness.syncEverything(profile: name) }
                confirmingProfile = nil
            }
            Button("Cancel", role: .cancel) { confirmingProfile = nil }
        } message: { name in
            Text(harness.syncEverythingSummary(for: name))
        }
    }

    @ViewBuilder
    private func header(_ harness: ProfileSyncHarness) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if harness.hasLoaded {
                if harness.allInSync {
                    Label("All in sync", systemImage: "checkmark.circle.fill")
                        .font(.subheadline).foregroundStyle(.green)
                } else {
                    Text("\(harness.totalDifferences) difference\(harness.totalDifferences == 1 ? "" : "s") across \(harness.profilesWithDrift) profile\(harness.profilesWithDrift == 1 ? "" : "s")")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.orange)
                }
            }
            Text("Pushes the default profile's current values: skills install the latest from the Skills Hub; config and credentials copy default's values. Nothing is deleted from a profile.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
                syncAll: { Task { await harness.syncAllConfig(profile: profile) } }
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

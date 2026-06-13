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
    /// payloads. Only surfaced on iPhone (the stacked `ConfigSubsection`); on
    /// desktop/iPad the comparison always shows *all* differences, so the curated
    /// filter doesn't apply — see ``curatedConfigOnly``.
    var showAllConfigDifferences = false

    /// Whether config push payloads should be restricted to the curated
    /// provider/model sections. The curated filter is an iPhone-only affordance:
    /// desktop/iPad show the full comparison and their "Sync all" pushes every
    /// pushable row, so "Sync everything" must do the same there (otherwise it
    /// would push a strict subset of what the Config section's own button does).
    var curatedConfigOnly: Bool { Idiom.isPhone && !showAllConfigDifferences }

    /// Profiles with a profile-level "Sync everything" in flight.
    private(set) var pushingProfiles: Set<String> = []
    /// Per-item push spinners, keyed by ``itemKey(_:profile:id:)``.
    private(set) var pushingItems: Set<String> = []

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
    private let configReader: @Sendable (String) async throws -> JSONValue
    private let envReader: @Sendable (String) async throws -> [EnvFileEntry]
    /// Server profile + transfer for the skill content-drift reads (the same
    /// read-only `HermesFileStore` path config/env use).
    private let serverProfile: ServerProfile?
    private let snapshotTransfer: RemoteSnapshotTransfer?

    private let engine = ProfileSyncEngine()
    private var namedProfiles: [String] = []
    /// Catalog index built from the last successful `catalog.skills()`.
    private var index: HubSkillIdentifierIndex?
    private var schema: DashboardConfigSchema?

    // MARK: - Skill content drift (unmanaged skills)

    /// Per profile: unmanaged (builtin/local) skills present in both default and
    /// the profile whose `SKILL.md` content differs — the customized/optimized
    /// drift the side-by-side panel inspects. Computed lazily when the Skills
    /// section opens.
    private(set) var modifiedSkills: [String: [ModifiedSkill]] = [:]
    private(set) var skillContentLoading: Set<String> = []
    private var skillContentLoaded: Set<String> = []
    /// Bumped whenever a refetch invalidates a profile's cached content drift, so
    /// the Skills section's lazy `.task` re-fires and recomputes it (a push
    /// refetches the selected profile, which would otherwise leave the
    /// "Customized" group gone until the user switches profiles and back).
    private(set) var skillContentToken = 0

    init(
        baseRunner: (any HermesAdminRunning)?,
        windowClient: @escaping @MainActor () -> DashboardClient?,
        profile: ServerProfile?,
        snapshotTransfer: RemoteSnapshotTransfer?,
        hermesVersion: HermesVersion?,
        catalog: SkillsHubCatalog = SkillsHubCatalog(),
        configReader: (@Sendable (String) async throws -> JSONValue)? = nil,
        envReader: (@Sendable (String) async throws -> [EnvFileEntry])? = nil
    ) {
        self.baseRunner = baseRunner
        self.windowClientProvider = windowClient
        self.catalog = catalog
        self.hermesVersion = hermesVersion
        self.serverProfile = profile
        self.snapshotTransfer = snapshotTransfer

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
        modifiedSkills.removeAll()
        skillContentLoading.removeAll()
        skillContentLoaded.removeAll()
        // Bump so the Skills section's `.task` re-fires after a manual Refresh
        // (selected profile unchanged → the token is the only id that moves).
        skillContentToken &+= 1
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

    /// In-flight per-profile loads, so concurrent ``selectProfile(_:)`` callers
    /// (the picker's `onChange` and the Skills section's content-drift task fire
    /// together on a switch) share one fetch instead of racing two.
    private var profileLoads: [String: Task<Void, Never>] = [:]

    /// Loads a single named profile on demand (the default snapshot + schema +
    /// catalog from the last ``refresh(namedProfiles:)`` are reused), so switching
    /// the picker doesn't re-fetch every profile. A no-op once it's cached;
    /// concurrent calls for the same profile coalesce onto one fetch.
    func selectProfile(_ name: String) async {
        if snapshots[name] != nil {
            if !namedProfiles.contains(name) {
                namedProfiles.append(name)
                recomputeDrift()
            }
            return
        }
        if let existing = profileLoads[name] {
            await existing.value
            return
        }
        let task = Task { await refreshProfile(name, addingToNamed: true) }
        profileLoads[name] = task
        await task.value
        profileLoads[name] = nil
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
        // A re-fetch invalidates this profile's cached content drift; bump the
        // token so the Skills section's `.task` re-fires and recomputes it.
        modifiedSkills[name] = nil
        skillContentLoaded.remove(name)
        skillContentToken &+= 1
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

    /// Computes content drift for **unmanaged** (builtin/local) skills present in
    /// both default and `profile`: reads each side's `SKILL.md` and diffs them,
    /// keeping the ones that differ (the customized/optimized skills). Hub-managed
    /// skills are excluded — they're pulled from the Hub, not hand-edited, and a
    /// default↔profile diff wouldn't reflect a Hub update anyway. Lazy + bounded;
    /// a skill that can't be read on a side is skipped.
    func loadSkillContentDrift(for profile: String) async {
        guard let serverProfile else { return }
        guard !skillContentLoaded.contains(profile), !skillContentLoading.contains(profile) else { return }
        // On a picker switch this runs concurrently with the picker's
        // `selectProfile`, which lazily fetches the snapshot. Ensure it's present
        // first (coalesced, so no double fetch) — otherwise the guard below loses
        // the race and content drift never re-fires until the user toggles away.
        await selectProfile(profile)
        guard !skillContentLoaded.contains(profile), !skillContentLoading.contains(profile) else { return }
        guard let defaultSkills = snapshots["default"]?.skills,
              let profileSkills = snapshots[profile]?.skills else { return }

        let profileNames = Set(profileSkills.map(\.name))
        let candidates = defaultSkills.filter { !$0.isHubManaged && profileNames.contains($0.name) }
        skillContentLoading.insert(profile)
        defer {
            skillContentLoading.remove(profile)
            skillContentLoaded.insert(profile)
        }
        guard !candidates.isEmpty else { modifiedSkills[profile] = []; return }

        let transfer = snapshotTransfer
        var result: [ModifiedSkill] = []
        await withTaskGroup(of: ModifiedSkill?.self) { group in
            let cap = 4
            var next = 0
            while next < min(cap, candidates.count) {
                let skill = candidates[next]; next += 1
                group.addTask { await Self.contentDrift(serverProfile: serverProfile, profile: profile, skill: skill, transfer: transfer) }
            }
            while let item = await group.next() {
                if let item { result.append(item) }
                if next < candidates.count {
                    let skill = candidates[next]; next += 1
                    group.addTask { await Self.contentDrift(serverProfile: serverProfile, profile: profile, skill: skill, transfer: transfer) }
                }
            }
        }
        result.sort { $0.name < $1.name }
        modifiedSkills[profile] = result
    }

    /// Reads and diffs one unmanaged skill's `SKILL.md` across the two profiles,
    /// returning a ``ModifiedSkill`` when the content differs. `nonisolated` so it
    /// runs off the main actor inside the read fan-out.
    nonisolated private static func contentDrift(
        serverProfile: ServerProfile,
        profile: String,
        skill: InstalledHubSkill,
        transfer: RemoteSnapshotTransfer?
    ) async -> ModifiedSkill? {
        do {
            async let defaultText = HermesSkillContentReader.read(
                profile: serverProfile, profileName: HermesProfiles.defaultProfileName,
                skillName: skill.name, category: skill.category, transfer: transfer
            )
            async let profileText = HermesSkillContentReader.read(
                profile: serverProfile, profileName: profile,
                skillName: skill.name, category: skill.category, transfer: transfer
            )
            let (left, right) = try await (defaultText, profileText)
            let rows = SkillDiff.sideBySide(default: left, profile: right)
            return rows.contains { $0.changed } ? ModifiedSkill(name: skill.name, category: skill.category, rows: rows) : nil
        } catch {
            return nil
        }
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

    // MARK: - Difference counts

    func differenceCount(for profile: String) -> Int {
        syncableSkillCount(for: profile)
            + syncableConfigCount(for: profile)
            + (envDrift[profile]?.items.count ?? 0)
    }

    /// Skill differences that can actually be pushed — installable-missing or
    /// outdated. Raw `items.count` includes skills that didn't resolve to a
    /// catalog identifier (`isActionable == false`): counting those overstated the
    /// pill and left "Sync everything" enabled while its summary said "Nothing to
    /// sync" (`skillAction(for:)` returns nil). Mirrors ``syncableConfigCount``.
    func syncableSkillCount(for profile: String) -> Int {
        skillsDrift[profile]?.items.filter(\.isActionable).count ?? 0
    }

    /// Config differences the active filter would actually *push* — pushable rows,
    /// curated unless "Show all config differences" is on. Counting raw
    /// `items.count` overstated the badge: it includes non-curated keys the
    /// subsection hides by default and the display-only `auxiliary.*.base_url`
    /// rows that are never pushed, so the pill could read "2 config" over an
    /// in-sync subsection whose "Sync everything" summary said "Nothing to sync".
    /// Matching the push payload keeps the badge, the subsection, and the summary
    /// in agreement.
    func syncableConfigCount(for profile: String) -> Int {
        configDrift[profile]?.pushPayload(curatedOnly: curatedConfigOnly).count ?? 0
    }

    // MARK: - Push: skills

    func syncSkill(_ item: SkillDriftItem, profile: String) async {
        guard let action = skillAction(for: item) else { return }
        let key = itemKey("skill", profile: profile, id: item.id)
        pushingItems.insert(key)
        let outcome = await engine.pushSkills(
            actions: [action], toProfile: profile, runnerProvider: makeRunnerProvider()
        ).first
        pushingItems.remove(key)
        await refreshProfile(profile)
        if let error = outcome?.error {
            banners?.surfaceError("profiles", error)
        } else {
            // Only check for a silent no-op when the push itself reported success
            // — a hard error already surfaced its own banner above.
            flagSilentSkillNoop(item, profile: profile, output: outcome?.output ?? "")
        }
    }

    /// `hermes skills install`/`update` can exit 0 without taking effect. If the
    /// push reported success but the skill is still drifting after the re-fetch,
    /// surface a short, actionable banner; the full Hermes output (often just
    /// progress noise) goes to the App Log rather than the banner.
    private func flagSilentSkillNoop(_ item: SkillDriftItem, profile: String, output: String) {
        guard let still = skillsDrift[profile]?.items.first(where: { $0.name == item.name }) else { return }
        let action: String
        let result: String
        switch still.kind {
        case .missing: action = "Installing"; result = "but the skill didn't appear"
        case .outdated: action = "Updating"; result = "but it's still out of date"
        }
        if !output.isEmpty {
            AppLog.general.error("Skill sync no-op: \(action, privacy: .public) “\(item.name, privacy: .public)” in “\(profile, privacy: .public)” reported success without effect. Hermes output: \(output, privacy: .public)")
        }
        banners?.surfaceError("profiles", "\(action) “\(item.name)” in “\(profile)” reported success \(result) (see App Logs).")
    }

    func syncAllSkills(profile: String) async {
        let actions = (skillsDrift[profile]?.items ?? []).compactMap(skillAction(for:))
        guard !actions.isEmpty else { return }
        pushingProfiles.insert(profile)
        defer { pushingProfiles.remove(profile) }
        let outcomes = await engine.pushSkills(actions: actions, toProfile: profile, runnerProvider: makeRunnerProvider())
        await refreshProfile(profile)
        surfaceFailures(outcomes.compactMap(\.error), profile: profile, noun: "skill")
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
        let error = await pushConfigEdits(edits, profile: profile)
        await refreshProfile(profile)
        if let error { banners?.surfaceError("profiles", error) }
    }

    private static let dashboardOfflineMessage = "The Hermes dashboard isn’t online yet. Wait for it to connect and try again."

    /// The window's dashboard client scoped to push into `profile` via
    /// `?profile=<name>` — the single dashboard serves every profile, so there's
    /// no separate process to acquire/release. Nil until the dashboard is online.
    private func scopedClient(_ profile: String) -> DashboardClient? {
        windowClientProvider()?.scoped(toProfile: profile)
    }

    /// Tail of the per-profile config-push chain, so cycles for one profile run
    /// strictly in order (see ``pushConfigEdits(_:profile:)``).
    private var configPushChains: [String: Task<String?, Never>] = [:]

    /// Pushes config edits into `profile` over the scoped window client,
    /// **serialized per profile**. `pushConfig` is a non-atomic GET-merge-PUT, and
    /// the per-row path gates only on a per-item key — so two rows pushed in quick
    /// succession could interleave (GET, GET, PUT, PUT) and the second PUT, built
    /// from a pre-first-PUT snapshot, would silently drop the first edit. Chaining
    /// each push behind the previous one for the same profile closes that window.
    /// Returns an error string on failure, nil on success.
    @discardableResult
    private func pushConfigEdits(_ edits: [String: ConfigValue], profile: String) async -> String? {
        let previous = configPushChains[profile]
        let task = Task { () -> String? in
            _ = await previous?.value
            guard let client = self.scopedClient(profile) else { return Self.dashboardOfflineMessage }
            return await self.engine.pushConfig(edits: edits, client: client).error
        }
        configPushChains[profile] = task
        return await task.value
    }

    // MARK: - Push: env

    func syncEnvItem(_ item: EnvDriftItem, profile: String) async {
        let id = item.key
        guard let value = plaintext(forKey: id) else {
            banners?.surfaceError("profiles", "Can't copy “\(id)” — default's value isn't loaded yet. Refresh and try again.")
            return
        }
        let key = itemKey("env", profile: profile, id: id)
        pushingItems.insert(key)
        defer { pushingItems.remove(key) }
        let error = await pushEnvItems([(key: id, value: value)], profile: profile).first ?? nil
        await refreshProfile(profile)
        if let error {
            banners?.surfaceError("profiles", error)
        } else if envDrift[profile]?.items.contains(where: { $0.key == id }) == true {
            // PUT /api/env returned OK but the re-read still shows the old value.
            // Don't guess why — capture the two paths actually involved (the home
            // the dashboard wrote to vs. the env file the reader checked) so the
            // divergence is visible instead of asserted.
            let diagnosis = await diagnoseEnvNoop(id: id, profile: profile)
            banners?.surfaceError("profiles", diagnosis)
        } else {
            banners?.surfaceSuccess("profiles", "Copied “\(id)” to “\(profile)”.")
        }
    }

    /// A `PUT /api/env` reported success yet the re-read still shows drift. Pin
    /// down *where* the write went vs. where we read by comparing the scoped
    /// dashboard's own resolved `env_path` (its write target) with the path the
    /// reader resolves via `hermes -p <profile> config env-path`. Both go to the
    /// App Log; the returned banner states the divergence (or, when the paths
    /// agree, that the write didn't land at the expected file). Best-effort — if
    /// either probe fails we fall back to a plain "didn't take effect" message.
    private func diagnoseEnvNoop(id: String, profile: String) async -> String {
        let fallback = "Couldn’t copy “\(id)” to “\(profile)”: Hermes reported success, but re-reading the profile’s .env still shows the old value. See the App Log for details."

        var dashboardEnvPath: String?
        if let client = scopedClient(profile) {
            dashboardEnvPath = try? await client.getStatus().envPath
        }

        var readerEnvPath: String?
        if let baseRunner {
            let runner = ProfileScopedHermesAdminRunner(inner: baseRunner, hermesProfileName: profile)
            if let result = try? await runner.run(HermesAdminCommand(arguments: ["config", "env-path"])) {
                let path = result.stdout
                    .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    .last(where: { !$0.isEmpty })
                readerEnvPath = path.flatMap { $0.isEmpty ? nil : $0 }
            }
        }

        AppLog.general.error("""
        Env copy no-op: “\(id, privacy: .public)” → “\(profile, privacy: .public)” reported success but the re-read still shows the old value. \
        Dashboard write target (env_path from /api/status): \(dashboardEnvPath ?? "unknown", privacy: .public). \
        Reader target (hermes -p \(profile, privacy: .public) config env-path): \(readerEnvPath ?? "unknown", privacy: .public).
        """)

        guard let dashboardEnvPath, let readerEnvPath else { return fallback }
        if dashboardEnvPath != readerEnvPath {
            return "Couldn’t copy “\(id)” to “\(profile)”: the dashboard wrote to \(dashboardEnvPath), but the profile reads from \(readerEnvPath). The scoped dashboard isn’t pointed at this profile’s home."
        }
        return "Couldn’t copy “\(id)” to “\(profile)”: Hermes reported success and targets \(readerEnvPath), but that file still shows the old value after the write. Check its write permissions."
    }

    func syncAllEnv(profile: String) async {
        let items = envPushItems(for: profile)
        guard !items.isEmpty else { return }
        pushingProfiles.insert(profile)
        defer { pushingProfiles.remove(profile) }
        let results = await pushEnvItems(items, profile: profile)
        await refreshProfile(profile)
        surfaceFailures(results.compactMap { $0 }, profile: profile, noun: "credential")
    }

    /// Pushes each key into `profile` over the scoped window client.
    /// Returns the per-key error strings (nil == success).
    private func pushEnvItems(_ items: [(key: String, value: String)], profile: String) async -> [String?] {
        guard let client = scopedClient(profile) else {
            return items.map { _ in Self.dashboardOfflineMessage }
        }
        return await engine.pushEnv(items: items, client: client).map(\.error)
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
    /// and env over the scoped window client, then re-snapshot. Honors the
    /// curated⇄all toggle for the config payload.
    func syncEverything(profile: String) async {
        pushingProfiles.insert(profile)
        defer { pushingProfiles.remove(profile) }

        // Collect every leg's failures and surface them together — otherwise a
        // failed skill install or credential copy in the batch is silent (the rows
        // just reappear after the refetch), unlike the per-section paths.
        var errors: [String] = []

        let actions = (skillsDrift[profile]?.items ?? []).compactMap(skillAction(for:))
        if !actions.isEmpty {
            let outcomes = await engine.pushSkills(actions: actions, toProfile: profile, runnerProvider: makeRunnerProvider())
            errors += outcomes.compactMap(\.error)
        }

        let configEdits = configDrift[profile]?.pushPayload(curatedOnly: curatedConfigOnly) ?? [:]
        if !configEdits.isEmpty {
            // Through the serialized path so a concurrent per-row config push for
            // the same profile can't clobber this merge (or vice versa).
            if let error = await pushConfigEdits(configEdits, profile: profile) { errors.append(error) }
        }
        let envItems = envPushItems(for: profile)
        if !envItems.isEmpty {
            if let client = scopedClient(profile) {
                errors += await engine.pushEnv(items: envItems, client: client).compactMap(\.error)
            } else {
                errors.append(Self.dashboardOfflineMessage)
            }
        }

        await refreshProfile(profile)
        surfaceFailures(errors, profile: profile, noun: "sync")
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
        let configCount = configDrift[profile]?.pushPayload(curatedOnly: curatedConfigOnly).count ?? 0
        if configCount > 0 { parts.append("push \(configCount) config value\(configCount == 1 ? "" : "s")") }
        let envCount = envPushItems(for: profile).count
        if envCount > 0 { parts.append("copy \(envCount) credential\(envCount == 1 ? "" : "s")") }
        guard !parts.isEmpty else { return "Nothing to sync to “\(profile)”." }
        return "This will \(parts.joined(separator: ", ")) to “\(profile)”."
    }

    func canSyncEverything(profile: String) -> Bool { differenceCount(for: profile) > 0 }

    // MARK: - Item bookkeeping

    func itemKey(_ resource: String, profile: String, id: String) -> String {
        "\(profile)|\(resource)|\(id)"
    }

    func isPushingItem(_ resource: String, profile: String, id: String) -> Bool {
        pushingItems.contains(itemKey(resource, profile: profile, id: id))
    }

    private func runItemPush(
        profile: String,
        resource: String,
        id: String,
        _ work: @escaping () async -> String?
    ) async {
        let key = itemKey(resource, profile: profile, id: id)
        pushingItems.insert(key)
        defer { pushingItems.remove(key) }
        if let error = await work() {
            banners?.surfaceError("profiles", error)
        }
    }

    /// Surfaces a batch of push failures on the standard top-of-window banner.
    private func surfaceFailures(_ errors: [String], profile: String, noun: String) {
        guard let first = errors.first else { return }
        let message = errors.count == 1
            ? first
            : "\(errors.count) \(noun) pushes to “\(profile)” failed: \(first)"
        banners?.surfaceError("profiles", message)
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
    /// A deep-link target set by the Profiles tab: when non-nil and valid, the
    /// view selects that profile and clears it.
    @Binding var syncTarget: String?

    @Environment(BannerCenter.self) private var banners: BannerCenter?

    @State private var harness: ProfileSyncHarness?
    /// Config comparison reuses the config editor's two-column view, source pinned
    /// to `default`. Desktop/iPad only (nil on iPhone, where Compare can't render).
    @State private var configEditor: ConfigEditorHarness?
    @State private var allProfiles: [HermesProfileInfo] = []
    @State private var namedProfiles: [String] = []
    @State private var selectedProfile: String?
    @State private var section: SyncSection = .skills
    @State private var configLoaded = false
    @State private var confirmingProfile: String?
    /// The skill comparison shown in the bottom panel (Skills section).
    @State private var skillDiff: SkillDiffPanel?

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
        // A deep-link arriving while the tab is already loaded selects that
        // profile (reload handles the first-appearance case).
        .onChange(of: syncTarget) { _, target in
            guard let harness, harness.hasLoaded, let target, namedProfiles.contains(target) else { return }
            syncTarget = nil
            if selectedProfile != target { selectedProfile = target }
        }
        .onDisappear {
            let editor = configEditor
            Task { await editor?.teardown() }
        }
    }

    /// Builds (once) and returns the harness, so the initial `.task` can use it
    /// immediately without waiting for the `@State` write to land. Also builds the
    /// config comparison harness (which scopes the window client per profile).
    private func ensureHarness() -> ProfileSyncHarness {
        if let harness { return harness }
        let provider = windowClient
        let h = ProfileSyncHarness(
            baseRunner: baseRunner,
            windowClient: provider,
            profile: profile,
            snapshotTransfer: snapshotTransfer,
            hermesVersion: hermesVersion
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
                transfer: snapshotTransfer
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
        if let target = syncTarget, namedProfiles.contains(target) {
            selectedProfile = target
            syncTarget = nil
        } else if selectedProfile == nil || !namedProfiles.contains(selectedProfile ?? "") {
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Sync from").foregroundStyle(.secondary)
                    Text(HermesProfiles.defaultProfileName).fontWeight(.semibold)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Picker("Target profile", selection: $selectedProfile) {
                        ForEach(namedProfiles, id: \.self) { Text($0).tag($0 as String?) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                    Spacer()
                    if let selected = selectedProfile {
                        let syncing = harness.pushingProfiles.contains(selected)
                        if syncing {
                            ProgressView().controlSize(.small)
                        }
                        Button("Sync everything from default") { confirmingProfile = selected }
                            // Disable while a sync is in flight: a second concurrent
                            // syncEverything would run unserialized skill/env legs and
                            // corrupt the shared `pushingProfiles` flag (whichever
                            // finishes first clears it). The phone row hides the button
                            // the same way.
                            .disabled(syncing)
                            .help("Install/update skills and copy config + credentials from default to “\(selected)”")
                            .accessibilityLabel("Sync everything from default to \(selected)")
                    }
                }
                if let selected = selectedProfile {
                    Text("Install / Update / Sync change “\(selected)”. “\(HermesProfiles.defaultProfileName)” is the read-only source.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                .padding(.bottom, 6)

                // Section-scoped "Sync all", below the tab bar (it acts on the
                // selected section, so it belongs with it rather than the picker).
                // Gated on having something actionable — not raw count — so it
                // never shows over a section whose only diffs are non-pushable.
                if sectionHasActionable(section, profile: selected, harness: harness) {
                    HStack {
                        Spacer()
                        Button("Sync all") { syncAllForSection(selected, harness: harness) }
                            .controlSize(.small)
                            .help("Push every \(section.rawValue.lowercased()) difference from default to “\(selected)”")
                            .accessibilityLabel("Sync all \(section.rawValue.lowercased()) from default to \(selected)")
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                }

                Divider()
                sectionContent(selected, harness: harness)
            }
        }
        // Switching the picker lazily loads that profile's drift (default + the
        // earlier profiles stay cached).
        .onChange(of: selectedProfile) { _, newValue in
            skillDiff = nil
            guard harness.hasLoaded, let newValue else { return }
            Task {
                await harness.selectProfile(newValue)
                if section == .config { activateConfigComparison() }
            }
        }
        .onChange(of: section) { _, _ in
            skillDiff = nil
            if section == .config { activateConfigComparison() }
        }
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

    /// Whether the section's "Sync all" would actually push anything — mirrors the
    /// per-subsection header gates (`isActionable` / `isPushable`). Raw
    /// `sectionCount` includes non-actionable rows (blocked skills, read-only
    /// config like `auxiliary.*.base_url`), so it can't gate the action: a button
    /// shown over only-non-actionable diffs no-ops when pressed (`syncAll*` builds
    /// an empty set and returns early). Config mirrors the desktop "Sync all",
    /// which pushes every pushable row (`curatedOnly: false`).
    private func sectionHasActionable(_ section: SyncSection, profile: String, harness: ProfileSyncHarness) -> Bool {
        switch section {
        case .skills:
            return harness.skillsDrift[profile]?.items.contains { $0.isActionable } ?? false
        case .config:
            return harness.configDrift[profile]?.items.contains { $0.isPushable } ?? false
        case .environment:
            return harness.envDrift[profile]?.items.isEmpty == false
        }
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
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        modifiedSkillsGroup(harness, profile: selected)
                        SkillsSubsection(harness: harness, profile: selected, showsSyncAllButton: false)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let panel = skillDiff {
                    Divider()
                    SkillDiffPanelView(
                        panel: panel,
                        defaultName: HermesProfiles.defaultProfileName,
                        profileName: selected,
                        onClose: { skillDiff = nil }
                    )
                    .frame(height: 340)
                }
            }
            // Detect content drift for unmanaged skills lazily when the Skills
            // section is shown, when the selected profile changes, and when a push
            // invalidates the cached drift (skillContentToken bumps on refetch).
            .task(id: "\(selected)#\(harness.skillContentToken)") {
                await harness.loadSkillContentDrift(for: selected)
            }
        case .config:
            configComparison(selected)
        case .environment:
            EnvComparisonView(harness: harness, profile: selected)
        }
    }

    /// The customized/optimized unmanaged skills whose `SKILL.md` drifts from
    /// default — each opens the read-only side-by-side panel from cached rows.
    @ViewBuilder
    private func modifiedSkillsGroup(_ harness: ProfileSyncHarness, profile: String) -> some View {
        if harness.skillContentLoading.contains(profile) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking customized skills…").font(.caption).foregroundStyle(.secondary)
            }
        } else if let modified = harness.modifiedSkills[profile], !modified.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Customized (differs from default)").font(.subheadline.weight(.semibold))
                Text("Unmanaged skills edited in this profile. Select one to see the diff (read-only).")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(modified) { skill in
                    Button { skillDiff = SkillDiffPanel(skillName: skill.name, rows: skill.rows) } label: {
                        HStack(spacing: 8) {
                            Text("modified")
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.yellow.opacity(0.18), in: Capsule())
                            Text(skill.name).font(.caption)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Compare default's “\(skill.name)” with “\(profile)”'s customized copy")
                }
            }
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
                    allowReverseCopy: false,
                    // Per-row copy must honor the same exclusion the bulk payload
                    // does — never let a stale `auxiliary.*.base_url` be pushed.
                    copyExcluded: { ConfigSyncScope.isExcludedFromPush(dotpath: $0) }
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
        let s = harness.syncableSkillCount(for: profile)
        let c = harness.syncableConfigCount(for: profile)
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
    /// Desktop hides the header's "Sync all" because the section bar above it
    /// already provides one; iPhone (no section bar) keeps it.
    var showsSyncAllButton = true

    var body: some View {
        let drift = harness.skillsDrift[profile]
        VStack(alignment: .leading, spacing: 6) {
            subsectionHeader(
                title: "Skills",
                inSync: drift?.isInSync ?? true,
                error: harness.resourceErrors[profile]?[.skills] ?? harness.defaultResourceErrors[.skills],
                showSyncAll: showsSyncAllButton && ((drift?.items.contains { $0.isActionable }) ?? false),
                syncAll: { Task { await harness.syncAllSkills(profile: profile) } }
            )
            if let drift {
                ForEach(drift.items) { item in
                    skillRow(item)
                }
                // Shown even when there's no missing/outdated drift — extras are
                // independent of the sync items.
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
    }

    private func valueText(_ value: ConfigValue) -> String {
        switch value {
        case let .string(s): return s.isEmpty ? "\"\"" : s
        case let .number(n):
            // `Int(n)` traps for non-finite or out-of-range values; mirror
            // `ProfileConfigForm.string`'s guard so a huge numeric leaf renders
            // instead of crashing the row.
            if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
            return String(n)
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
            if let drift {
                ForEach(drift.items) { item in
                    envRow(item)
                }
                // Shown even when in sync — extras are independent of the items.
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
        // Source → target, matching the config rows (`default → profile`) and the
        // "Sync from default → <profile>" header. `defaultPart` (the revealable
        // source value) sits on the left; the profile's current value on the right.
        let defaultPart = revealed ? (plaintext() ?? redactedDefault) : redactedDefault
        return "\(defaultPart) → \(redactedProfile ?? "—")"
    }
}

// MARK: - Skill comparison bottom panel

/// An unmanaged skill whose `SKILL.md` differs between default and a profile,
/// with the precomputed side-by-side rows so opening the panel needs no re-read.
struct ModifiedSkill: Identifiable, Equatable {
    let name: String
    let category: String?
    let rows: [SkillDiffRow]
    var id: String { name }
}

/// State for the skill comparison shown in the Skills section's bottom panel.
/// Inspect-only — the rows are precomputed during content-drift detection.
private struct SkillDiffPanel {
    let skillName: String
    let rows: [SkillDiffRow]
}

/// A bottom-anchored, read-only side-by-side comparison of a customized skill's
/// `SKILL.md`: the default profile (left) against the selected profile (right).
/// Anchored at the bottom (not the side) so the two columns get the full width.
private struct SkillDiffPanelView: View {
    let panel: SkillDiffPanel
    let defaultName: String
    let profileName: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.split.2x1")
                Text(panel.skillName).font(.headline).lineLimit(1)
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Close comparison")
                    .help("Close the comparison")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            HStack(spacing: 1) {
                Text(defaultName).frame(maxWidth: .infinity, alignment: .leading)
                Text(profileName).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            Divider()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(panel.rows) { row in
                    HStack(alignment: .top, spacing: 1) {
                        diffCell(row.left, changed: row.changed)
                        diffCell(row.right, changed: row.changed)
                    }
                }
            }
        }
    }

    private func diffCell(_ text: String?, changed: Bool) -> some View {
        Text(text ?? " ")
            .font(.system(.caption2, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(cellBackground(text: text, changed: changed))
            .textSelection(.enabled)
    }

    private func cellBackground(text: String?, changed: Bool) -> Color {
        guard changed else { return .clear }
        // A present-but-different line is highlighted; a gap (the other side has a
        // line this one lacks) gets a faint fill so the alignment reads.
        return text == nil ? Color.secondary.opacity(0.08) : Color.yellow.opacity(0.18)
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

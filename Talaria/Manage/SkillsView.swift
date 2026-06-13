import HermesKit
import SwiftUI

/// Which lifecycle actions a row offers, derived from `hermes skills list`.
/// `hub` → Update / Audit / Remove; `builtin` → Reset (+ Repair when official);
/// `local` → Publish. `nil` (unknown / no admin runner) offers none.
enum SkillKind {
    case hub
    case local
    case builtin
}

/// A captured `skills audit` report awaiting presentation in a sheet.
struct SkillAuditReport: Identifiable {
    let name: String
    let text: String
    var id: String { name }
}

@MainActor
@Observable
final class SkillsHarness {
    // Dashboard-backed installed list + enabled state (the table's source).
    var rows: [DashboardSkill] = []
    var isLoading: Bool = false
    var lastError: String?
    /// Top-of-window banner hub (window-scoped). Hard errors route here keyed by
    /// ``bannerKey`` so they render full-width across the top. Optional so a
    /// missing host degrades to no-op.
    var banners: BannerCenter?
    /// Surface id used to key this list's banners ("skills"), set by the view.
    var bannerKey: String = "list"
    var selectionID: String?
    var toggling: Set<String> = []

    // Skills Hub search (HTTP catalog — works without the admin runner).
    var searchQuery: String = ""
    var searchResults: [HubCatalogSkill] = []
    var searching: Bool = false
    var catalogError: String?
    /// The query that actually produced `searchResults`. Lets the UI tell
    /// "searched and found nothing" apart from "haven't searched this text yet",
    /// so the empty-state copy only shows once a search has really run.
    var lastSearchedQuery: String?

    // Install-from-identifier form.
    var installIdentifier: String = ""
    /// Identifier currently installing (from either the search list or the
    /// manual form), so exactly that row/button shows progress and disables.
    var installingIdentifier: String?
    /// Green confirmation line shown after a successful install; cleared when
    /// the next install starts.
    var lastInstallMessage: String?

    /// Names of installed skills that came from the hub (eligible for Update /
    /// Remove), derived from `hermes skills list`. Empty when no admin runner.
    var hubInstalledNames: Set<String> = []
    /// Names of installed skills whose Source is exactly `local` (user-created,
    /// neither builtin nor Hub), derived from the same `hermes skills list`.
    /// Empty when no admin runner.
    var localNames: Set<String> = []
    /// Hub skills with an upstream update available (from `hermes skills check`),
    /// populated off `refresh()` so each row can flag "Update available".
    var updatableNames: Set<String> = []
    /// Names whose Source is exactly `builtin` (shipped with Hermes), eligible
    /// for Reset (and Repair when also official). Empty when no admin runner.
    var builtinNames: Set<String> = []
    /// Names whose Trust is `official` — the subset of builtins eligible for the
    /// `repair-official` action. Empty when no admin runner.
    var officialNames: Set<String> = []
    /// Names with an in-flight per-skill action (update/audit/reset/repair/
    /// remove/publish), to disable their buttons.
    var busy: Set<String> = []
    /// Single in-flight flag for the global bundled-seeding actions
    /// (opt-out / opt-in / re-seed), which aren't keyed by a skill name.
    var seedingBusy: Bool = false
    /// Captured `skills audit` report awaiting presentation; cleared on dismiss.
    var auditReport: SkillAuditReport?

    private let client: DashboardClient
    let runner: HermesAdminRunning?
    private let catalog: SkillsHubCatalog
    /// The profile's configured Hermes home (local profiles only), used to
    /// resolve the on-disk skills root for Publish and Force remove.
    let hermesHome: String?

    init(
        client: DashboardClient,
        runner: HermesAdminRunning?,
        hermesHome: String? = nil,
        catalog: SkillsHubCatalog = SkillsHubCatalog()
    ) {
        self.client = client
        self.runner = runner
        self.hermesHome = hermesHome
        self.catalog = catalog
    }

    /// The local skills root (`<hermesHome>/skills`, default `~/.hermes/skills`).
    var skillsRoot: URL { HermesSkillsFileStore.localSkillsRoot(hermesHome: hermesHome) }

    /// The currently-selected installed skill, or nil. Drives the detail panel.
    var selected: DashboardSkill? { rows.first { $0.name == selectionID } }

    /// True once the manual install field has a non-empty identifier.
    var canInstallFromField: Bool {
        !installIdentifier.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func isHubManaged(_ name: String) -> Bool { hubInstalledNames.contains(name) }

    func isLocal(_ name: String) -> Bool { localNames.contains(name) }

    /// True when this builtin skill is official-trust (eligible for Repair).
    func isOfficial(_ name: String) -> Bool { officialNames.contains(name) }

    /// Classifies a row so it can pick its lifecycle actions. Returns `nil` when
    /// the skill isn't in the CLI list yet (no admin runner, or a transient
    /// dashboard/CLI mismatch), in which case the row offers no kind-specific
    /// actions.
    func kind(for name: String) -> SkillKind? {
        if hubInstalledNames.contains(name) { return .hub }
        if localNames.contains(name) { return .local }
        if builtinNames.contains(name) { return .builtin }
        return nil
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            rows = try await client.listSkills()
            lastError = nil
            banners?.dismiss(key: bannerKey)
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
        await refreshHubInstalled()
        // Probe every hub skill for upstream updates fire-and-forget so the
        // "Update available" badges populate without adding network latency to
        // `refresh()` (which also runs on every enable/disable toggle).
        Task { await refreshUpdatable() }
    }

    /// Populates `hubInstalledNames` from the CLI list when an admin runner is
    /// available. A failure here is non-fatal (search + toggle still work), so
    /// it's recorded to `lastError` only if the dashboard list itself succeeded.
    private func refreshHubInstalled() async {
        guard let runner else {
            hubInstalledNames = []
            localNames = []
            builtinNames = []
            officialNames = []
            return
        }
        do {
            let installed = try await HermesSkillsHub.listInstalled(runner: runner)
            hubInstalledNames = Set(installed.filter(\.isHubManaged).map(\.name))
            localNames = Set(installed.filter(\.isLocal).map(\.name))
            builtinNames = Set(installed.filter(\.isBuiltin).map(\.name))
            officialNames = Set(installed.filter(\.isOfficial).map(\.name))
        } catch {
            hubInstalledNames = []
            localNames = []
            builtinNames = []
            officialNames = []
            if lastError == nil {
                lastError = error.localizedDescription
                banners?.surfaceError(bannerKey, error.localizedDescription)
            }
        }
    }

    func setEnabled(_ name: String, enabled: Bool) async {
        toggling.insert(name)
        defer { toggling.remove(name) }
        do {
            try await client.toggleSkill(name: name, enabled: enabled)
            // Refresh so the row reflects what the server actually persisted —
            // dashboard returns 200 on toggle without a body, so we read back.
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    // MARK: - Search

    func search() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            lastSearchedQuery = nil
            return
        }
        searching = true
        defer { searching = false }
        do {
            // First call triggers the cached fetch; subsequent searches in the
            // TTL window hit the in-memory/disk cache.
            _ = try await catalog.skills()
            searchResults = await catalog.search(query)
            lastSearchedQuery = query
            catalogError = nil
        } catch {
            searchResults = []
            lastSearchedQuery = nil
            catalogError = error.localizedDescription
        }
    }

    // MARK: - Mutations (CLI fallback)

    func install(identifier: String, displayName: String? = nil) async {
        let trimmed = identifier.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let runner else { return }
        installingIdentifier = trimmed
        lastInstallMessage = nil
        defer { installingIdentifier = nil }
        do {
            _ = try await HermesSkillsHub.install(runner: runner, identifier: trimmed)
            if installIdentifier.trimmingCharacters(in: .whitespaces) == trimmed {
                installIdentifier = ""
            }
            await refresh()
            let name = displayName ?? trimmed
            lastInstallMessage = "Installed \(name). Available in your next session."
            // Highlight the freshly installed row when the refreshed list
            // contains it, as a visual confirmation.
            if let displayName, rows.contains(where: { $0.name == displayName }) {
                selectionID = displayName
            }
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    func update(_ name: String) async {
        guard let runner else { return }
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            _ = try await HermesSkillsHub.update(runner: runner, name: name)
            updatableNames.remove(name)
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    /// Checks every installed hub skill for an upstream update in one
    /// `hermes skills check` call so each row's "Update available" badge can
    /// flag it. Network-bound, so it runs fire-and-forget off `refresh()` and is
    /// best-effort — a slow or failed check leaves the badges absent rather than
    /// surfacing an error on the surface.
    func refreshUpdatable() async {
        guard let runner, !hubInstalledNames.isEmpty else { return }
        do {
            let statuses = try await HermesSkillsHub.checkUpdates(runner: runner)
            updatableNames = Set(statuses.filter(\.updateAvailable).map(\.name))
        } catch {
            // Best-effort hint only — leave `updatableNames` untouched.
        }
    }

    func remove(_ name: String) async {
        guard let runner else { return }
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            try await HermesSkillsHub.uninstall(runner: runner, name: name)
            // Drop the selection so the table highlight doesn't dangle on a
            // name that no longer exists after the refresh.
            if selectionID == name { selectionID = nil }
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    /// Force-removes a skill by deleting its directory directly — the fallback
    /// for builtin/local skills (which `hermes skills uninstall` refuses) and for
    /// a stuck hub uninstall. Local profiles only (gated by the caller); deletion
    /// is fast local filesystem I/O so it runs on the MainActor like the other
    /// mutators.
    func forceRemove(_ name: String, category: String?) async {
        guard runner?.deliversStdin == true else { return }
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            try HermesSkillsFileStore.forceDelete(skillsRoot: skillsRoot, category: category, name: name)
            if selectionID == name { selectionID = nil }
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    // MARK: - Lifecycle actions (CLI fallback)

    /// Re-scans a hub skill and captures the report into `auditReport` for the
    /// presentation sheet. Doesn't mutate state, so it skips the post-refresh.
    func audit(_ name: String) async {
        guard let runner else { return }
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            let report = try await HermesSkillsHub.audit(runner: runner, name: name)
            auditReport = SkillAuditReport(
                name: name,
                text: report.isEmpty ? "Audit completed — no issues reported." : report
            )
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    /// Clears a builtin skill's `user-modified` tracking (safe `skills reset`).
    func reset(_ name: String) async {
        guard let runner else { return }
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            _ = try await HermesSkillsHub.reset(runner: runner, name: name)
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    /// Backfills an official skill's hub metadata (safe `skills repair-official`).
    func repair(_ name: String) async {
        guard let runner else { return }
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            _ = try await HermesSkillsHub.repairOfficial(runner: runner, name: name)
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    /// Publishes a local skill directory to a registry. `path` is the on-disk
    /// skill directory (from the publish sheet); `name` keys the busy flag and
    /// the confirmation. Surfaces a success banner on completion.
    func publish(name: String, path: String, registry: SkillsPublishRegistry, repo: String?) async {
        guard let runner else { return }
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            _ = try await HermesSkillsHub.publish(runner: runner, path: path, registry: registry, repo: repo)
            banners?.surfaceSuccess(bannerKey, "Published \(name) to \(registry.rawValue).")
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    // MARK: - Bundled-skill seeding (global, not keyed by name)

    /// Stops bundled skills from seeding into this profile (safe `skills
    /// opt-out`). Guards the shared `seedingBusy` flag.
    func optOut() async {
        await runSeeding { try await HermesSkillsHub.optOut(runner: $0) }
    }

    /// Re-enables bundled-skill seeding (`skills opt-in`).
    func optIn() async {
        await runSeeding { try await HermesSkillsHub.optIn(runner: $0) }
    }

    /// Re-enables and immediately re-seeds bundled skills (`skills opt-in
    /// --sync`).
    func reseed() async {
        await runSeeding { try await HermesSkillsHub.optIn(runner: $0, sync: true) }
    }

    /// Shared driver for the three bundled-seeding actions: single in-flight
    /// guard, run the closure, refresh on success, route errors to the banner.
    private func runSeeding(_ body: @escaping (HermesAdminRunning) async throws -> String) async {
        guard let runner, !seedingBusy else { return }
        seedingBusy = true
        defer { seedingBusy = false }
        do {
            _ = try await body(runner)
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }
}

struct SkillsView: View {
    let client: DashboardClient?
    let runner: HermesAdminRunning?
    let hermesVersion: HermesVersion?
    let hermesHome: String?

    /// Window's top-of-window banner hub. Optional so a host that doesn't supply
    /// one degrades to no-op (hard errors then simply don't render).
    @Environment(BannerCenter.self) private var banners: BannerCenter?
    /// Window navigator: a skill `EntityLink` (e.g. from a chat permission
    /// prompt) selects its row when this tab lands. Optional so the view renders
    /// without one.
    @Environment(WindowNavigator.self) private var navigator: WindowNavigator?

    @State private var harness: SkillsHarness?
    // Both hub sections collapse by default so the installed list owns the
    // pane; the user expands them on demand to search or paste an identifier.
    @State private var searchExpanded = false
    @State private var installExpanded = false
    /// The local skill currently being published (drives the publish sheet), or
    /// `nil` when no sheet is up.
    @State private var publishTarget: PublishTarget?
    /// Confirms the destructive-ish opt-out from the Bundled skills menu.
    @State private var confirmingOptOut = false

    init(
        client: DashboardClient?,
        runner: HermesAdminRunning? = nil,
        hermesVersion: HermesVersion? = nil,
        hermesHome: String? = nil
    ) {
        self.client = client
        self.runner = runner
        self.hermesVersion = hermesVersion
        self.hermesHome = hermesHome
    }

    /// Whether the Skills Hub install/update affordances can run: they need the
    /// CLI admin runner and work over any transport (local or remote SSH/NIO).
    private var mutationsAvailable: Bool { runner != nil }

    /// Whether **Remove** can run. `hermes skills uninstall` has no `--yes` in
    /// v0.14.0 and is confirmed by feeding `y\n` on stdin — only the local macOS
    /// runner delivers stdin to the child, so remote (SSH/NIO) profiles can't
    /// uninstall yet. Gate Remove (not Install/Update) on that capability rather
    /// than letting a remote uninstall read closed stdin and fail with a
    /// confusing "Cancelled." error.
    private var removeAvailable: Bool { runner?.deliversStdin == true }

    /// Whether the lifecycle affordances (Audit / Reset / Repair / Publish and
    /// the Bundled skills menu) can run: they need the CLI admin runner and a
    /// Hermes new enough to expose the subcommands. Below the gate the
    /// in-surface `capabilityBanner` explains why; runtime `commandUnavailable`
    /// is the real backstop.
    private var lifecycleAvailable: Bool {
        runner != nil && CapabilityTable().has(.skillsLifecycle, in: hermesVersion)
    }

    /// Whether **Publish** can run. Publish operates on a *local* skill
    /// directory, so — like Remove — it's gated on the runner actually being the
    /// local one (only it can reach the on-disk skill path). Remote SSH/NIO
    /// profiles can't publish a local directory.
    private var publishAvailable: Bool { runner?.deliversStdin == true }

    /// Whether **Force remove** can run. It deletes a local skill directory, so
    /// — like Publish/Remove — it requires the local runner. Remote SSH/NIO
    /// profiles have no delete transport.
    private var forceRemoveAvailable: Bool { runner?.deliversStdin == true }

    var body: some View {
        Group {
            if client == nil {
                ContentUnavailableView(
                    "Dashboard not ready",
                    systemImage: "wand.and.stars",
                    description: Text("Waiting for the Hermes dashboard to come online.")
                )
            } else if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Skills")
        .dismissesBanner("skills", from: banners)
        // Keyed on client availability so the harness is built when the
        // dashboard finishes booting and `client` flips non-nil, not only on
        // first appear (a bare `.task` on the Group never re-runs for that flip).
        .task(id: client != nil) {
            guard let client else { harness = nil; return }
            if harness != nil { consumeFocus(harness: harness!); return }
            let h = SkillsHarness(client: client, runner: runner, hermesHome: hermesHome)
            h.banners = banners
            h.bannerKey = "skills"
            harness = h
            await h.refresh()
            consumeFocus(harness: h)
        }
        .onAppear { if let harness { consumeFocus(harness: harness) } }
        .onChange(of: navigator?.pendingFocus) { _, _ in
            if let harness { consumeFocus(harness: harness) }
        }
    }

    /// Selects the row named by a pending skill focus, then clears it. Ignores
    /// focus aimed at another tab/page.
    private func consumeFocus(harness: SkillsHarness) {
        guard let ref = navigator?.pendingFocus, case let .skill(id) = ref else { return }
        if harness.rows.contains(where: { $0.name == id }) {
            harness.selectionID = id
        }
        Task { @MainActor in navigator?.pendingFocus = nil }
    }

    @ViewBuilder
    private func content(harness: SkillsHarness) -> some View {
        // Reachable only from the desktop window's Browse sidebar (macOS +
        // iPad); the iPhone shell has no Browse, so this never renders there.
        // A single self-contained list — each row expands in place to show the
        // full description and hub actions, so there's no secondary pane.
        primaryPane(harness: harness)
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await harness.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(harness.isLoading)
                .help("Refresh the skills list")
            }
            ToolbarItem {
                bundledSkillsMenu(harness: harness)
            }
        }
        // Hard errors route to the top-of-window strip; only the capability warning stays in-surface.
        .manageBanner(
            capabilityBanner(
                .requiresDashboard,
                feature: "Skills via Hermes dashboard",
                version: hermesVersion
            )
                ?? capabilityBanner(
                    .skillsHub,
                    feature: "Installing, updating and removing Skills Hub skills",
                    version: hermesVersion
                )
                ?? capabilityBanner(
                    .skillsLifecycle,
                    feature: "Auditing, resetting, repairing, publishing and bundled-skill opt-in/out",
                    version: hermesVersion
                ),
            severity: .warning
        )
        .alert("Opt out of bundled skills?", isPresented: $confirmingOptOut) {
            Button("Cancel", role: .cancel) {}
            Button("Opt out") { Task { await harness.optOut() } }
        } message: {
            Text("Stops built-in skills from seeding into this profile. Already-installed copies are left in place.")
        }
        .sheet(item: $publishTarget) { target in
            PublishSheet(skillName: target.skillName, defaultPath: target.path) { path, registry, repo in
                Task { await harness.publish(name: target.skillName, path: path, registry: registry, repo: repo) }
            }
        }
        .sheet(item: Binding(
            get: { harness.auditReport },
            set: { harness.auditReport = $0 }
        )) { report in
            AuditReportSheet(report: report)
        }
    }

    /// Bundled-skill seeding actions, grouped in one toolbar menu. Gated behind
    /// ``lifecycleAvailable``; below the gate the in-surface `capabilityBanner`
    /// explains why.
    @ViewBuilder
    private func bundledSkillsMenu(harness: SkillsHarness) -> some View {
        Menu {
            Button {
                confirmingOptOut = true
            } label: {
                Label("Opt out of bundled skills", systemImage: "xmark.circle")
            }
            .help("Stops built-in skills from seeding into this profile")

            Button {
                Task { await harness.optIn() }
            } label: {
                Label("Opt back in", systemImage: "checkmark.circle")
            }
            .help("Re-enables seeding of built-in skills into this profile")

            Button {
                Task { await harness.reseed() }
            } label: {
                Label("Re-seed bundled skills now", systemImage: "arrow.clockwise.circle")
            }
            .help("Re-enables seeding and copies the built-in skills in immediately")
        } label: {
            Label("Bundled skills", systemImage: "shippingbox")
        }
        .menuIndicator(.visible)
        .disabled(!lifecycleAvailable || harness.seedingBusy)
        .help("Opt in or out of seeding Hermes' built-in skills into this profile")
    }

    // MARK: - Primary pane (search + install form + table)

    @ViewBuilder
    private func primaryPane(harness: SkillsHarness) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                searchSection(harness: harness)
                Divider()
                installSection(harness: harness)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            skillsList(harness: harness)
        }
    }

    @ViewBuilder
    private func searchSection(harness: SkillsHarness) -> some View {
        DisclosureGroup(isExpanded: $searchExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Search by name, description or tag", text: Binding(
                        get: { harness.searchQuery },
                        set: { harness.searchQuery = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await harness.search() } }
                    if harness.searching {
                        ProgressView().controlSize(.small)
                    }
                    Button("Search") {
                        Task { await harness.search() }
                    }
                    .disabled(harness.searching
                        || harness.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let error = harness.catalogError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                searchResults(harness: harness)
            }
            .padding(.top, 4)
        } label: {
            Text("Search the Skills Hub").font(.headline)
        }
    }

    @ViewBuilder
    private func searchResults(harness: SkillsHarness) -> some View {
        if harness.searchResults.isEmpty {
            // Only after a search actually ran for the *current* text — not
            // while the user is still typing a query they haven't submitted.
            if !harness.searching,
               harness.catalogError == nil,
               harness.lastSearchedQuery == harness.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) {
                Text("No matching skills.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            // Bounded height so a long result list scrolls within the section
            // rather than pushing the installed-skills table off-screen.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(harness.searchResults) { result in
                        SkillSearchRow(
                            result: result,
                            installed: harness.rows.contains(where: { $0.name == result.name }),
                            installing: harness.installingIdentifier == result.identifier,
                            canInstall: mutationsAvailable && harness.installingIdentifier == nil,
                            onInstall: {
                                Task { await harness.install(identifier: result.identifier, displayName: result.name) }
                            }
                        )
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 220)
        }
    }

    @ViewBuilder
    private func installSection(harness: SkillsHarness) -> some View {
        DisclosureGroup(isExpanded: $installExpanded) {
            Form {
                TextField("official/… or https://…/SKILL.md", text: Binding(
                    get: { harness.installIdentifier },
                    set: { harness.installIdentifier = $0 }
                ))
                HStack(spacing: 8) {
                    if let message = harness.lastInstallMessage {
                        Label(message, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .lineLimit(2)
                    }
                    if !mutationsAvailable {
                        Text("Admin runner unavailable — search still works.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if harness.installingIdentifier != nil { ProgressView().controlSize(.small) }
                    Button("Install") {
                        Task { await harness.install(identifier: harness.installIdentifier) }
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!mutationsAvailable || harness.installingIdentifier != nil || !harness.canInstallFromField)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Install from identifier / URL").font(.headline)
        }
    }

    @ViewBuilder
    private func skillsList(harness: SkillsHarness) -> some View {
        // A grouped, inline-expanding list (like the Environment screen): each
        // row collapses to a summary and grows in place when selected to reveal
        // the full description and the hub Update / Remove actions — no pane.
        List(selection: Binding(
            get: { harness.selectionID },
            set: { harness.selectionID = $0 }
        )) {
            ForEach(harness.rows) { skill in
                SkillRow(
                    skill: skill,
                    isExpanded: harness.selectionID == skill.name,
                    kind: harness.kind(for: skill.name),
                    isOfficial: harness.isOfficial(skill.name),
                    updateAvailable: harness.updatableNames.contains(skill.name),
                    mutationsAvailable: mutationsAvailable,
                    removeAvailable: removeAvailable,
                    lifecycleAvailable: lifecycleAvailable,
                    publishAvailable: publishAvailable,
                    busy: harness.busy.contains(skill.name),
                    toggling: harness.toggling.contains(skill.name),
                    onToggle: { enabled in Task { await harness.setEnabled(skill.name, enabled: enabled) } },
                    onUpdate: { Task { await harness.update(skill.name) } },
                    onRemove: { Task { await harness.remove(skill.name) } },
                    onAudit: { Task { await harness.audit(skill.name) } },
                    onReset: { Task { await harness.reset(skill.name) } },
                    onRepair: { Task { await harness.repair(skill.name) } },
                    onPublish: { publishTarget = PublishTarget(skillName: skill.name, path: defaultPublishPath(for: skill)) }
                )
                .tag(skill.name)
            }
        }
        .overlay {
            if harness.rows.isEmpty, !harness.isLoading {
                ContentUnavailableView("No skills", systemImage: "wand.and.stars")
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The on-disk directory a skill occupies under the local skills root
    /// (`<hermesHome>/skills/[<category>/]<name>`, `hermesHome` from the profile,
    /// default `~/.hermes`). `skills list` doesn't expose the path, so this is the
    /// default the Publish sheet pre-fills and the path the Force-remove
    /// confirmation names.
    private func skillDirectoryPath(for skill: DashboardSkill) -> String {
        var url = HermesSkillsFileStore.localSkillsRoot(hermesHome: hermesHome)
        if let category = skill.category, !category.isEmpty {
            url.appendPathComponent(category, isDirectory: true)
        }
        url.appendPathComponent(skill.name, isDirectory: true)
        return url.path
    }
}

/// Identifies the local skill being published, seeding the publish sheet.
private struct PublishTarget: Identifiable {
    let skillName: String
    let path: String
    var id: String { skillName }
}

/// One Skills Hub search result row: identity + trust + description, with an
/// Install button (or an "Installed" marker when it's already present).
private struct SkillSearchRow: View {
    let result: HubCatalogSkill
    let installed: Bool
    let installing: Bool
    let canInstall: Bool
    let onInstall: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(result.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    SkillPill(text: result.source, color: .secondary)
                    if !result.trustLevel.isEmpty {
                        SkillPill(text: result.trustLevel, color: trustColor(result.trustLevel))
                    }
                }
                if !result.description.isEmpty {
                    Text(result.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(result.identifier)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if installed {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .help("Already installed")
            } else if installing {
                ProgressView().controlSize(.small)
            } else {
                Button("Install", action: onInstall)
                    .controlSize(.small)
                    .disabled(!canInstall)
                    .help("Install this skill")
            }
        }
        .padding(.vertical, 6)
    }

    private func trustColor(_ trust: String) -> Color {
        switch trust {
        case "builtin", "trusted", "official": return .green
        case "community": return .orange
        default: return .secondary
        }
    }
}

/// One inline-expanding row in the installed-skills list (mirroring the
/// Environment screen's `EnvVarRow`). Collapsed, it shows the skill name (with a
/// Hub/Local badge and an update hint), a one-line description preview, its
/// category, and the enable toggle. Selected (`isExpanded`) it grows in place to
/// reveal the full description and a **kind-appropriate** action cluster — hub:
/// Update / Audit / Remove; builtin: Repair (official only) / Reset; local:
/// Publish. `confirmingRemove` is per-row state, so the Remove confirmation
/// lives here rather than on the harness.
private struct SkillRow: View {
    let skill: DashboardSkill
    let isExpanded: Bool
    let kind: SkillKind?
    let isOfficial: Bool
    let updateAvailable: Bool
    let mutationsAvailable: Bool
    let removeAvailable: Bool
    let lifecycleAvailable: Bool
    let publishAvailable: Bool
    let busy: Bool
    let toggling: Bool
    let onToggle: (Bool) -> Void
    let onUpdate: () -> Void
    let onRemove: () -> Void
    let onAudit: () -> Void
    let onReset: () -> Void
    let onRepair: () -> Void
    let onPublish: () -> Void

    @State private var confirmingRemove = false

    /// True when there's a non-empty description to show.
    private var hasDescription: Bool { !(skill.description ?? "").isEmpty }

    var body: some View {
        // Header (name + toggle) and a detail row beneath it. The description
        // always lives in the detail row — same position, gap and font whether
        // the row is selected or not — so expanding only un-truncates the text
        // and reveals the actions, never shifts the description.
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    switch kind {
                    case .hub:
                        SkillPill(text: "Hub", color: .blue)
                    case .local:
                        SkillPill(text: "Local", color: .secondary)
                    case .builtin, .none:
                        EmptyView()
                    }
                    if updateAvailable {
                        Image(systemName: "arrow.up.circle")
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .help("An update is available from the source")
                            .accessibilityLabel("Update available")
                    }
                }

                Spacer(minLength: 8)

                if let category = skill.category, !category.isEmpty {
                    Text(category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Toggle("", isOn: Binding(
                    get: { skill.enabled },
                    set: { onToggle($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(toggling)
            }

            detailRow
        }
        .padding(.vertical, 6)
        .padding(.trailing, 4)
        .alert("Remove \(skill.name)?", isPresented: $confirmingRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { onRemove() }
        } message: {
            Text("This deletes the installed skill from the Hermes host.")
        }
    }

    /// The description (left) and, when expanded, the kind-appropriate actions
    /// (right) on one shared row — like the Environment screen. The description
    /// is single-line when collapsed and wraps when expanded, but its
    /// position/size never change, so selecting a row isn't visually jarring.
    @ViewBuilder
    private var detailRow: some View {
        if hasDescription || (isExpanded && kind != nil) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if hasDescription {
                    Text(skill.description ?? "")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(isExpanded ? nil : 1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // Keep the actions pinned right even with no description.
                    Spacer(minLength: 0)
                }

                // The action cluster differs by skill kind, and only shows once
                // the row is expanded.
                if isExpanded, let kind {
                    actions(for: kind)
                }
            }
        }
    }

    /// Trailing-aligned, kind-specific action buttons with any explanatory
    /// caption directly beneath them.
    @ViewBuilder
    private func actions(for kind: SkillKind) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                switch kind {
                case .hub:
                    hubButtons
                case .builtin:
                    builtinButtons
                case .local:
                    localButtons
                }
                if busy { ProgressView().controlSize(.small) }
            }
            caption(for: kind)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// hub: Update / Audit / Remove.
    @ViewBuilder
    private var hubButtons: some View {
        Button {
            onUpdate()
        } label: {
            Label("Update", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(busy || !mutationsAvailable)
        .help("Pull the latest version from the source")

        Button {
            onAudit()
        } label: {
            Label("Audit", systemImage: "checkmark.shield")
        }
        .disabled(busy || !lifecycleAvailable)
        .help("Re-scan this skill and show the security report")

        Button(role: .destructive) {
            confirmingRemove = true
        } label: {
            Label("Remove", systemImage: "trash")
        }
        .disabled(busy || !removeAvailable)
        .help("Uninstall this skill from the Hermes host")
    }

    /// builtin: Repair (official only) / Reset.
    @ViewBuilder
    private var builtinButtons: some View {
        if isOfficial {
            Button {
                onRepair()
            } label: {
                Label("Repair", systemImage: "bandage")
            }
            .disabled(busy || !lifecycleAvailable)
            .help("Backfill this official skill's hub metadata")
        }

        Button {
            onReset()
        } label: {
            Label("Reset", systemImage: "arrow.uturn.backward")
        }
        .disabled(busy || !lifecycleAvailable)
        .help("Clear this skill's user-modified tracking")
    }

    /// local: Publish.
    @ViewBuilder
    private var localButtons: some View {
        Button {
            onPublish()
        } label: {
            Label("Publish", systemImage: "square.and.arrow.up")
        }
        .disabled(busy || !publishAvailable || !lifecycleAvailable)
        .help("Publish this local skill to a registry")
    }

    /// Per-kind explanatory caption for unavailable affordances.
    @ViewBuilder
    private func caption(for kind: SkillKind) -> some View {
        switch kind {
        case .hub:
            if !mutationsAvailable {
                captionText("Admin runner unavailable.")
            } else if !removeAvailable {
                // Update works over SSH/NIO; uninstall needs a local stdin
                // prompt (no `--yes` in v0.14.0), so Remove is disabled here.
                captionText("Remove is unavailable on remote profiles.")
            }
        case .local:
            if !publishAvailable {
                captionText("Publish is available on local profiles only.")
            }
        case .builtin:
            EmptyView()
        }
    }

    private func captionText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Tinted rounded capsule for source / trust / status labels, matching the
/// `PluginPill` styling on the Plugins surface.
private struct SkillPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color == .secondary ? Color.secondary : color)
            .lineLimit(1)
    }
}

/// Sheet for publishing a **local** skill to a registry. Holds the editable
/// registry / repo / path locally and reports the chosen values back through
/// `onPublish`. `path` is seeded from a derived default (publish's positional
/// arg is a directory `skills list` doesn't expose), so it stays editable.
private struct PublishSheet: View {
    let skillName: String
    let onPublish: (String, SkillsPublishRegistry, String?) -> Void

    @State private var path: String
    @State private var registry: SkillsPublishRegistry = .github
    @State private var repo: String = ""
    @Environment(\.dismiss) private var dismiss

    init(
        skillName: String,
        defaultPath: String,
        onPublish: @escaping (String, SkillsPublishRegistry, String?) -> Void
    ) {
        self.skillName = skillName
        self.onPublish = onPublish
        self._path = State(initialValue: defaultPath)
    }

    /// github always needs a repo; clawhub's is optional. The path is always
    /// required (it's publish's positional directory argument).
    private var canPublish: Bool {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if registry == .github {
            return !repo.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Publish “\(skillName)”")
                .font(.headline)

            Form {
                Picker("Registry", selection: $registry) {
                    Text("GitHub").tag(SkillsPublishRegistry.github)
                    Text("ClawHub").tag(SkillsPublishRegistry.clawhub)
                }
                .pickerStyle(.segmented)

                TextField(
                    registry == .github ? "owner/repo" : "owner/repo (optional)",
                    text: $repo
                )

                TextField("Skill directory path", text: $path)
            }
            .formStyle(.grouped)

            if registry == .clawhub {
                Text("ClawHub can infer the repository; leave it blank to use the default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Dismiss without publishing")
                Button("Publish") {
                    let trimmedRepo = repo.trimmingCharacters(in: .whitespaces)
                    onPublish(
                        path.trimmingCharacters(in: .whitespaces),
                        registry,
                        trimmedRepo.isEmpty ? nil : trimmedRepo
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canPublish)
                .help("Publish this skill to the selected registry")
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}

/// Sheet presenting a captured `skills audit` report — scrollable, monospaced,
/// with a Done button. Dismissing clears `auditReport` via the `.sheet(item:)`
/// binding.
private struct AuditReportSheet: View {
    let report: SkillAuditReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audit: \(report.name)")
                .font(.headline)

            ScrollView {
                Text(report.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 200, maxHeight: 360)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .help("Dismiss the audit report")
            }
        }
        .padding(20)
        .frame(minWidth: 480)
    }
}

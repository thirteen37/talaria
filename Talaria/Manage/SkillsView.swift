import HermesKit
import SwiftUI

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
    /// Hub skills with an upstream update available (from `hermes skills check`),
    /// populated off `refresh()` so each row can flag "Update available".
    var updatableNames: Set<String> = []
    /// Names with an in-flight update/remove action, to disable their buttons.
    var busy: Set<String> = []

    private let client: DashboardClient
    let runner: HermesAdminRunning?
    private let catalog: SkillsHubCatalog

    init(client: DashboardClient, runner: HermesAdminRunning?, catalog: SkillsHubCatalog = SkillsHubCatalog()) {
        self.client = client
        self.runner = runner
        self.catalog = catalog
    }

    /// True once the manual install field has a non-empty identifier.
    var canInstallFromField: Bool {
        !installIdentifier.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func isHubManaged(_ name: String) -> Bool { hubInstalledNames.contains(name) }

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
            return
        }
        do {
            let installed = try await HermesSkillsHub.listInstalled(runner: runner)
            hubInstalledNames = Set(installed.filter(\.isHubManaged).map(\.name))
        } catch {
            hubInstalledNames = []
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
}

struct SkillsView: View {
    let client: DashboardClient?
    let runner: HermesAdminRunning?
    let hermesVersion: HermesVersion?

    /// Window's top-of-window banner hub. Optional so a host that doesn't supply
    /// one degrades to no-op (hard errors then simply don't render).
    @Environment(BannerCenter.self) private var banners: BannerCenter?

    @State private var harness: SkillsHarness?
    // Both hub sections collapse by default so the installed list owns the
    // pane; the user expands them on demand to search or paste an identifier.
    @State private var searchExpanded = false
    @State private var installExpanded = false

    init(client: DashboardClient?, runner: HermesAdminRunning? = nil, hermesVersion: HermesVersion? = nil) {
        self.client = client
        self.runner = runner
        self.hermesVersion = hermesVersion
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
            if harness != nil { return }
            let h = SkillsHarness(client: client, runner: runner)
            h.banners = banners
            h.bannerKey = "skills"
            harness = h
            await h.refresh()
        }
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
                ),
            severity: .warning
        )
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
                    isHubManaged: harness.isHubManaged(skill.name),
                    updateAvailable: harness.updatableNames.contains(skill.name),
                    mutationsAvailable: mutationsAvailable,
                    removeAvailable: removeAvailable,
                    busy: harness.busy.contains(skill.name),
                    toggling: harness.toggling.contains(skill.name),
                    onToggle: { enabled in Task { await harness.setEnabled(skill.name, enabled: enabled) } },
                    onUpdate: { Task { await harness.update(skill.name) } },
                    onRemove: { Task { await harness.remove(skill.name) } }
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
/// Hub badge and an update hint), a one-line description preview, its category,
/// and the enable toggle. Selected (`isExpanded`) it grows in place to reveal
/// the full description and the Skills Hub Update / Remove actions — the content
/// that used to live in the detail pane. `confirmingRemove` is per-row state, so
/// the Remove confirmation lives here rather than on the harness.
private struct SkillRow: View {
    let skill: DashboardSkill
    let isExpanded: Bool
    let isHubManaged: Bool
    let updateAvailable: Bool
    let mutationsAvailable: Bool
    let removeAvailable: Bool
    let busy: Bool
    let toggling: Bool
    let onToggle: (Bool) -> Void
    let onUpdate: () -> Void
    let onRemove: () -> Void

    @State private var confirmingRemove = false

    /// True when there's a non-empty description to show.
    private var hasDescription: Bool { !(skill.description ?? "").isEmpty }

    var body: some View {
        // Header (name + toggle) and a detail row beneath it. The description
        // always lives in the detail row — same position, gap and font whether
        // the row is selected or not — so expanding only un-truncates the text
        // and reveals the hub actions, never shifts the description.
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isHubManaged {
                        SkillPill(text: "Hub", color: .blue)
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

    /// The description (left) and, when expanded, the hub actions (right) on one
    /// shared row — like the Environment screen. The description is single-line
    /// when collapsed and wraps when expanded, but its position/size never
    /// change, so selecting a row isn't visually jarring.
    @ViewBuilder
    private var detailRow: some View {
        if hasDescription || (isExpanded && isHubManaged) {
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

                // Update / Remove are offered only for hub-installed skills
                // (builtin and local skills aren't managed by the hub and can't
                // be removed this way), once the row is expanded.
                if isExpanded, isHubManaged {
                    actions
                }
            }
        }
    }

    /// Trailing-aligned Update / Remove buttons with the explanatory caption
    /// directly beneath them.
    private var actions: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    onUpdate()
                } label: {
                    Label("Update", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(busy || !mutationsAvailable)
                .help("Pull the latest version from the source")

                Button(role: .destructive) {
                    confirmingRemove = true
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .disabled(busy || !removeAvailable)
                .help("Uninstall this skill from the Hermes host")

                if busy { ProgressView().controlSize(.small) }
            }
            if !mutationsAvailable {
                Text("Admin runner unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !removeAvailable {
                // Update works over SSH/NIO; uninstall needs a local stdin
                // prompt (no `--yes` in v0.14.0), so Remove is disabled here.
                Text("Remove is unavailable on remote profiles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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

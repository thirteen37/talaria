import HermesKit
import SwiftUI

@MainActor
@Observable
final class SkillsHarness {
    // Dashboard-backed installed list + enabled state (the table's source).
    var rows: [DashboardSkill] = []
    var isLoading: Bool = false
    var lastError: String?
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
    /// populated lazily so the detail pane can flag "Update available".
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

    var selected: DashboardSkill? {
        guard let id = selectionID else { return nil }
        return rows.first(where: { $0.name == id })
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
        } catch {
            lastError = error.localizedDescription
        }
        await refreshHubInstalled()
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
            if lastError == nil { lastError = error.localizedDescription }
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
            // Select the freshly installed row when the refreshed list contains
            // it, so its detail pane opens as confirmation.
            if let displayName, rows.contains(where: { $0.name == displayName }) {
                selectionID = displayName
            }
        } catch {
            lastError = error.localizedDescription
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
        }
    }

    /// Lazily checks one hub skill for an upstream update so the detail pane can
    /// flag it, run when a hub skill is selected. `hermes skills check` hits the
    /// network, so it's scoped to the single selected skill (not the whole list)
    /// and is best-effort — a slow or failed check leaves the hint absent rather
    /// than surfacing an error on the surface.
    func checkForUpdate(_ name: String) async {
        guard let runner, hubInstalledNames.contains(name) else { return }
        do {
            let statuses = try await HermesSkillsHub.checkUpdates(runner: runner, name: name)
            if statuses.contains(where: { $0.name == name && $0.updateAvailable }) {
                updatableNames.insert(name)
            } else {
                updatableNames.remove(name)
            }
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
            // Drop the selection so the detail pane doesn't dangle on a name
            // that no longer exists after the refresh.
            if selectionID == name { selectionID = nil }
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

struct SkillsView: View {
    let client: DashboardClient?
    let runner: HermesAdminRunning?
    let hermesVersion: HermesVersion?

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
        // Keyed on client availability so the harness is built when the
        // dashboard finishes booting and `client` flips non-nil, not only on
        // first appear (a bare `.task` on the Group never re-runs for that flip).
        .task(id: client != nil) {
            guard let client else { harness = nil; return }
            if harness != nil { return }
            let h = SkillsHarness(client: client, runner: runner)
            harness = h
            await h.refresh()
        }
    }

    @ViewBuilder
    private func content(harness: SkillsHarness) -> some View {
        // Reachable only from the desktop window's Browse sidebar (macOS +
        // iPad); the iPhone shell has no Browse, so this never renders there.
        // `PlatformSplit` is a resizable `HSplitView` on macOS and an
        // `HStack`+`Divider` on iPad — no `#if`.
        PlatformSplit(showsSecondary: harness.selected != nil) {
            primaryPane(harness: harness)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        } secondary: {
            previewPane(harness: harness)
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        }
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
        .manageBanner(
            harness.lastError
                ?? capabilityBanner(
                    .requiresDashboard,
                    feature: "Skills via Hermes dashboard",
                    version: hermesVersion
                )
                ?? capabilityBanner(
                    .skillsHub,
                    feature: "Installing, updating and removing Skills Hub skills",
                    version: hermesVersion
                ),
            severity: harness.lastError != nil ? .error : .warning
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
            skillsTable(harness: harness)
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
    private func skillsTable(harness: SkillsHarness) -> some View {
        Table(harness.rows, selection: Binding(
            get: { harness.selectionID },
            set: { harness.selectionID = $0 }
        )) {
            TableColumn("Name") { row in
                Text(row.name)
            }
            TableColumn("Enabled") { row in
                Toggle("", isOn: Binding(
                    get: { row.enabled },
                    set: { newValue in
                        Task { await harness.setEnabled(row.name, enabled: newValue) }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(harness.toggling.contains(row.name))
            }
            .width(70)
            TableColumn("Category") { row in
                Text(row.category ?? "")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .overlay {
            if harness.rows.isEmpty, !harness.isLoading {
                ContentUnavailableView("No skills", systemImage: "wand.and.stars")
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        .id(harness.rows.map(\.name).joined())
    }

    // MARK: - Detail pane

    // Rendered only when a skill is selected — `PlatformSplit`'s
    // `showsSecondary` gate hides this pane entirely otherwise, so there's no
    // unselected placeholder branch.
    @ViewBuilder
    private func previewPane(harness: SkillsHarness) -> some View {
        if let skill = harness.selected {
            SkillDetail(
                skill: skill,
                isHubManaged: harness.isHubManaged(skill.name),
                updateAvailable: harness.updatableNames.contains(skill.name),
                mutationsAvailable: mutationsAvailable,
                removeAvailable: removeAvailable,
                busy: harness.busy.contains(skill.name),
                onUpdate: { Task { await harness.update(skill.name) } },
                onRemove: { Task { await harness.remove(skill.name) } }
            )
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Lazily probe the selected hub skill for an upstream update; re-runs
            // when the selection changes. No-op for builtin/local skills.
            .task(id: skill.name) {
                await harness.checkForUpdate(skill.name)
            }
        }
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

private struct SkillDetail: View {
    let skill: DashboardSkill
    let isHubManaged: Bool
    let updateAvailable: Bool
    let mutationsAvailable: Bool
    let removeAvailable: Bool
    let busy: Bool
    let onUpdate: () -> Void
    let onRemove: () -> Void

    @State private var confirmingRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(skill.name)
                .font(.headline)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Image(systemName: skill.enabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(skill.enabled ? .green : .secondary)
                Text(skill.enabled ? "Enabled" : "Disabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let category = skill.category, !category.isEmpty {
                    Text("· \(category)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isHubManaged {
                    SkillPill(text: "Hub", color: .blue)
                }
            }
            if let description = skill.description, !description.isEmpty {
                Divider()
                Text(description)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Update / Remove are offered only for hub-installed skills (builtin
            // and local skills aren't managed by the hub and can't be removed
            // this way).
            if isHubManaged {
                Divider()
                if updateAvailable {
                    Label("Update available", systemImage: "arrow.up.circle")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
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
            Spacer()
        }
        .id(skill.name)
        .alert("Remove \(skill.name)?", isPresented: $confirmingRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { onRemove() }
        } message: {
            Text("This deletes the installed skill from the Hermes host.")
        }
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

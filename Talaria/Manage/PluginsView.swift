import HermesKit
import SwiftUI

/// Sentinel tag for the memory picker's "Built-in (none)" row — Hermes treats
/// an empty `memory.provider` string as the built-in provider.
private let builtInMemoryTag = ""

@MainActor
@Observable
final class PluginsHarness {
    var plugins: [DashboardPlugin] = []
    var providers: DashboardPluginProviders?

    // Draft provider selections, seeded from `providers` on each refresh.
    var draftMemory: String = builtInMemoryTag
    var draftContext: String = ""

    // Install-from-GitHub form.
    var installIdentifier: String = ""
    var installForce: Bool = false
    var installEnable: Bool = true

    var isLoading: Bool = false
    var savingProviders: Bool = false
    var installing: Bool = false
    var lastError: String?
    /// Top-of-window banner hub (window-scoped); optional so a missing host
    /// degrades to no-op. Hard errors route here keyed by the surface id; a
    /// successful provider save posts a transient confirmation.
    var banners: BannerCenter?
    /// Green confirmation line shown under the Install form after a successful
    /// install; cleared when the next install starts.
    var lastInstallMessage: String?
    var selectionID: String?
    /// Names of plugins with an in-flight enable/disable/update/remove action,
    /// so their detail-pane buttons disable while the request is outstanding.
    var busy: Set<String> = []

    private let client: DashboardClient

    init(client: DashboardClient) {
        self.client = client
    }

    var selected: DashboardPlugin? {
        guard let id = selectionID else { return nil }
        return plugins.first(where: { $0.name == id })
    }

    /// True once the drafts diverge from the loaded provider selections — gates
    /// the Save button so an unchanged form stays inert.
    var providersDirty: Bool {
        guard let providers else { return false }
        return draftMemory != providers.memoryProvider || draftContext != providers.contextEngine
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let hub = try await client.getPluginsHub()
            // Preserve unsaved provider edits across refreshes: a plugin action
            // (enable/disable/update/remove/install) refreshes the whole hub, and
            // blindly reseeding here would silently discard an in-progress picker
            // selection. Only reseed when the form has no pending changes — which
            // includes first load (`providersDirty` is false while `providers` is
            // nil) and the post-save refresh (drafts already equal the saved
            // values, so they survive untouched).
            let preserveDrafts = providersDirty
            plugins = hub.plugins
            providers = hub.providers
            if !preserveDrafts {
                draftMemory = hub.providers.memoryProvider
                draftContext = hub.providers.contextEngine
            }
            lastError = nil
            banners?.dismiss(key: "plugins")
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError("plugins", error.localizedDescription)
        }
    }

    func saveProviders() async {
        savingProviders = true
        defer { savingProviders = false }
        do {
            try await client.setPluginProviders(memoryProvider: draftMemory, contextEngine: draftContext)
            await refresh()
            // Only confirm if the post-write reload also succeeded — otherwise
            // refresh() has posted its own error and an unconditional success
            // here would dismiss it, hiding a failed reload over stale data.
            if lastError == nil {
                banners?.surfaceSuccess("plugins", "Providers saved")
            }
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError("plugins", error.localizedDescription)
        }
    }

    func install() async {
        let identifier = installIdentifier.trimmingCharacters(in: .whitespaces)
        guard !identifier.isEmpty else { return }
        installing = true
        defer { installing = false }
        lastInstallMessage = nil
        do {
            let result = try await client.installPlugin(
                identifier: identifier, force: installForce, enable: installEnable
            )
            installIdentifier = ""
            await refresh()
            lastInstallMessage = installSummary(result, identifier: identifier)
            // Select the freshly installed row (when the server named it and the
            // refreshed list contains it) so its detail pane opens as confirmation.
            if let installedName = result.pluginName,
               plugins.contains(where: { $0.name == installedName }) {
                selectionID = installedName
            }
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError("plugins", error.localizedDescription)
        }
    }

    /// Builds the green confirmation line from the server's install result —
    /// the resolved name, whether it was enabled, and any required-env /
    /// warning caveats the user should act on.
    private func installSummary(_ result: DashboardPluginInstallResult, identifier: String) -> String {
        let name = result.pluginName ?? identifier
        var parts = ["Installed \(name)\(result.enabled ? " and enabled it" : "")."]
        if !result.missingEnv.isEmpty {
            parts.append("Set required env: \(result.missingEnv.joined(separator: ", ")).")
        }
        parts.append(contentsOf: result.warnings)
        return parts.joined(separator: " ")
    }

    func setEnabled(_ plugin: DashboardPlugin, enabled: Bool) async {
        busy.insert(plugin.name)
        defer { busy.remove(plugin.name) }
        do {
            try await client.setPluginEnabled(name: plugin.name, enabled: enabled)
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError("plugins", error.localizedDescription)
        }
    }

    func update(_ plugin: DashboardPlugin) async {
        busy.insert(plugin.name)
        defer { busy.remove(plugin.name) }
        do {
            try await client.updatePlugin(name: plugin.name)
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError("plugins", error.localizedDescription)
        }
    }

    func remove(_ plugin: DashboardPlugin) async {
        busy.insert(plugin.name)
        defer { busy.remove(plugin.name) }
        do {
            try await client.removePlugin(name: plugin.name)
            // Drop the selection so the detail pane doesn't dangle on a name
            // that no longer exists after the refresh.
            if selectionID == plugin.name { selectionID = nil }
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError("plugins", error.localizedDescription)
        }
    }
}

struct PluginsView: View {
    let client: DashboardClient?
    let hermesVersion: HermesVersion?

    @Environment(BannerCenter.self) private var banners: BannerCenter?
    /// Window navigator: a plugin `EntityLink` selects its row when this tab
    /// lands. Optional so the view renders without one.
    @Environment(WindowNavigator.self) private var navigator: WindowNavigator?

    @State private var harness: PluginsHarness?
    // The two config sections collapse by default so the plugin list owns the
    // pane; the user expands them on demand to change providers or install.
    @State private var providersExpanded = false
    @State private var installExpanded = false

    init(client: DashboardClient?, hermesVersion: HermesVersion? = nil) {
        self.client = client
        self.hermesVersion = hermesVersion
    }

    var body: some View {
        Group {
            if client == nil {
                ContentUnavailableView(
                    "Dashboard not ready",
                    systemImage: "puzzlepiece.extension",
                    description: Text("Waiting for the Hermes dashboard to come online.")
                )
            } else if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Plugins")
        .dismissesBanner("plugins", from: banners)
        // Keyed on client availability so the harness is built when the
        // dashboard finishes booting and `client` flips non-nil, not only on
        // first appear (a bare `.task` on the Group never re-runs for that flip).
        .task(id: client != nil) {
            guard let client else { harness = nil; return }
            if harness != nil { consumeFocus(harness: harness!); return }
            let h = PluginsHarness(client: client)
            h.banners = banners
            harness = h
            await h.refresh()
            consumeFocus(harness: h)
        }
        .onAppear { if let harness { consumeFocus(harness: harness) } }
        .onChange(of: navigator?.pendingFocus) { _, _ in
            if let harness { consumeFocus(harness: harness) }
        }
    }

    /// Selects the row named by a pending plugin focus, then clears it. Ignores
    /// focus aimed at another tab/page.
    private func consumeFocus(harness: PluginsHarness) {
        guard let ref = navigator?.pendingFocus, case let .plugin(name) = ref else { return }
        if harness.plugins.contains(where: { $0.name == name }) {
            harness.selectionID = name
        }
        Task { @MainActor in navigator?.pendingFocus = nil }
    }

    @ViewBuilder
    private func content(harness: PluginsHarness) -> some View {
        // Reached from the desktop window's Browse sidebar (macOS + iPad) and
        // from the iPhone Browse sheet, which pushes this through
        // `BrowseDetailView`. `PlatformSplit` is a resizable `HSplitView` on
        // macOS and a plain `HStack`+`Divider` on iOS (iPad + iPhone) — no `#if`.
        // Keep the pane minimums modest (matching `SkillsView`) so the two
        // side-by-side panes don't force an over-wide layout on a phone screen.
        PlatformSplit(
            showsSecondary: Binding(
                get: { harness.selected != nil },
                set: { if !$0 { harness.selectionID = nil } }
            ),
            secondaryTitle: harness.selected?.name,
            secondaryBadges: detailBadges(harness)
        ) {
            primaryPane(harness: harness)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        } secondary: {
            detailPane(harness: harness)
                .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await harness.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(harness.isLoading)
                .help("Refresh the plugins list")
            }
        }
        // Hard errors route to the top-of-window strip; only the capability
        // warning stays in-surface.
        .manageBanner(
            capabilityBanner(
                .requiresDashboard,
                feature: "Plugins via Hermes dashboard",
                version: hermesVersion
            ),
            severity: .warning
        )
    }

    /// Badges shown in the selected plugin's panel header: source, version,
    /// runtime status, and (when absent) a "no dashboard tab" marker.
    private func detailBadges(_ harness: PluginsHarness) -> [PanelBadge] {
        guard let plugin = harness.selected else { return [] }
        var badges: [PanelBadge] = [
            PanelBadge(text: plugin.source),
            PanelBadge(text: plugin.version),
            PanelBadge(text: plugin.statusLabel, tint: plugin.statusColor),
        ]
        if !plugin.hasDashboardManifest {
            badges.append(PanelBadge(text: "No dashboard tab"))
        }
        return badges
    }

    // MARK: - Primary pane (providers + install form + table)

    @ViewBuilder
    private func primaryPane(harness: PluginsHarness) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                providerSection(harness: harness)
                Divider()
                installSection(harness: harness)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            pluginsTable(harness: harness)
        }
    }

    @ViewBuilder
    private func providerSection(harness: PluginsHarness) -> some View {
        DisclosureGroup(isExpanded: $providersExpanded) {
            if let providers = harness.providers {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        Picker("Memory Provider", selection: Binding(
                            get: { harness.draftMemory },
                            set: { harness.draftMemory = $0 }
                        )) {
                            Text("Built-in (none)").tag(builtInMemoryTag)
                            ForEach(providers.memoryOptions) { option in
                                Text(option.name).tag(option.name)
                            }
                        }
                        .fixedSize()
                        Picker("Context Engine", selection: Binding(
                            get: { harness.draftContext },
                            set: { harness.draftContext = $0 }
                        )) {
                            ForEach(providers.contextOptions) { option in
                                Text(option.name).tag(option.name)
                            }
                        }
                        .fixedSize()
                        Spacer()
                    }
                    HStack {
                        Text("Takes effect next session.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Save") {
                            Task { await harness.saveProviders() }
                        }
                        .disabled(harness.savingProviders || !harness.providersDirty)
                    }
                }
                .padding(.top, 4)
            } else {
                Text("Provider options unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            Text("Runtime Provider Plugins").font(.headline)
        }
    }

    @ViewBuilder
    private func installSection(harness: PluginsHarness) -> some View {
        DisclosureGroup(isExpanded: $installExpanded) {
            Form {
                TextField("owner/repo or https://…", text: Binding(
                    get: { harness.installIdentifier },
                    set: { harness.installIdentifier = $0 }
                ))
                Toggle("Force reinstall", isOn: Binding(
                    get: { harness.installForce },
                    set: { harness.installForce = $0 }
                ))
                Toggle("Enable after install", isOn: Binding(
                    get: { harness.installEnable },
                    set: { harness.installEnable = $0 }
                ))
                HStack(spacing: 8) {
                    if let message = harness.lastInstallMessage {
                        Label(message, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .lineLimit(2)
                    }
                    Spacer()
                    if harness.installing {
                        ProgressView().controlSize(.small)
                    }
                    Button("Install") {
                        Task { await harness.install() }
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(
                        harness.installing
                        || harness.installIdentifier.trimmingCharacters(in: .whitespaces).isEmpty
                    )
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Install from GitHub / Git URL").font(.headline)
        }
    }

    @ViewBuilder
    private func pluginsTable(harness: PluginsHarness) -> some View {
        Table(harness.plugins, selection: Binding(
            get: { harness.selectionID },
            set: { harness.selectionID = $0 }
        )) {
            TableColumn("Name") { plugin in
                Text(plugin.name)
            }
            TableColumn("Source") { plugin in
                PanelBadgeView(badge: PanelBadge(text: plugin.source))
            }
            .width(90)
            TableColumn("Version") { plugin in
                Text(plugin.version)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(80)
            TableColumn("Status") { plugin in
                PanelBadgeView(badge: PanelBadge(text: plugin.statusLabel, tint: plugin.statusColor))
            }
            .width(90)
        }
        .overlay {
            if harness.plugins.isEmpty, !harness.isLoading {
                ContentUnavailableView("No plugins", systemImage: "puzzlepiece.extension")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(harness.plugins.map(\.name).joined())
    }

    // MARK: - Detail pane

    // Rendered only when a plugin is selected — `PlatformSplit`'s
    // `showsSecondary` gate hides this pane entirely otherwise, so there's no
    // unselected placeholder branch.
    @ViewBuilder
    private func detailPane(harness: PluginsHarness) -> some View {
        if let plugin = harness.selected {
            PluginDetail(
                plugin: plugin,
                busy: harness.busy.contains(plugin.name),
                onSetEnabled: { enabled in Task { await harness.setEnabled(plugin, enabled: enabled) } },
                onUpdate: { Task { await harness.update(plugin) } },
                onRemove: { Task { await harness.remove(plugin) } }
            )
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Single source of truth for how a plugin's `runtime_status` renders as a
/// pill, shared by the installed-plugins table and the detail pane so the two
/// can't drift. `Color` lives in SwiftUI, so this app-side extension (not
/// `DashboardPlugin` in HermesKit) owns the mapping.
extension DashboardPlugin {
    var statusLabel: String {
        runtimeStatus.prefix(1).uppercased() + runtimeStatus.dropFirst()
    }

    var statusColor: Color {
        switch runtimeStatus {
        case "enabled": return .green
        case "inactive": return .orange
        default: return .secondary
        }
    }
}

private struct PluginDetail: View {
    let plugin: DashboardPlugin
    let busy: Bool
    let onSetEnabled: (Bool) -> Void
    let onUpdate: () -> Void
    let onRemove: () -> Void

    @State private var confirmingRemove = false

    private var isEnabled: Bool { plugin.runtimeStatus == "enabled" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !plugin.description.isEmpty {
                Text(plugin.description)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if plugin.authRequired {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Label("Authentication required", systemImage: "key.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    if !plugin.authCommand.isEmpty {
                        Text(plugin.authCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            HStack(spacing: 8) {
                Button {
                    onSetEnabled(!isEnabled)
                } label: {
                    Label(isEnabled ? "Disable" : "Enable",
                          systemImage: isEnabled ? "pause.circle" : "play.circle")
                }
                .disabled(busy)

                if plugin.canUpdateGit {
                    Button {
                        onUpdate()
                    } label: {
                        Label("Update", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(busy)
                }

                if plugin.canRemove {
                    Button(role: .destructive) {
                        confirmingRemove = true
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .disabled(busy)
                }

                if busy { ProgressView().controlSize(.small) }
            }

            Spacer()
        }
        .id(plugin.name)
        .alert("Remove \(plugin.name)?", isPresented: $confirmingRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { onRemove() }
        } message: {
            Text("This deletes the installed plugin from the Hermes host.")
        }
    }
}

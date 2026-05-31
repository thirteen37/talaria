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
            plugins = hub.plugins
            providers = hub.providers
            draftMemory = hub.providers.memoryProvider
            draftContext = hub.providers.contextEngine
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func saveProviders() async {
        savingProviders = true
        defer { savingProviders = false }
        do {
            try await client.setPluginProviders(memoryProvider: draftMemory, contextEngine: draftContext)
            await refresh()
        } catch {
            lastError = error.localizedDescription
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
        }
    }
}

struct PluginsView: View {
    let client: DashboardClient?
    let hermesVersion: HermesVersion?

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
        // Keyed on client availability so the harness is built when the
        // dashboard finishes booting and `client` flips non-nil, not only on
        // first appear (a bare `.task` on the Group never re-runs for that flip).
        .task(id: client != nil) {
            guard let client else { harness = nil; return }
            if harness != nil { return }
            let h = PluginsHarness(client: client)
            harness = h
            await h.refresh()
        }
    }

    @ViewBuilder
    private func content(harness: PluginsHarness) -> some View {
        // Reached from the desktop window's Browse sidebar (macOS + iPad) and
        // from the iPhone Browse sheet, which pushes this through
        // `BrowseDetailView`. `PlatformSplit` is a resizable `HSplitView` on
        // macOS and a plain `HStack`+`Divider` on iOS (iPad + iPhone) — no `#if`.
        // Keep the pane minimums modest (matching `SkillsView`) so the two
        // side-by-side panes don't force an over-wide layout on a phone screen.
        PlatformSplit(showsSecondary: harness.selected != nil) {
            primaryPane(harness: harness)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        } secondary: {
            detailPane(harness: harness)
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
                .help("Refresh the plugins list")
            }
        }
        .manageBanner(
            harness.lastError ?? capabilityBanner(
                .requiresDashboard,
                feature: "Plugins via Hermes dashboard",
                version: hermesVersion
            ),
            severity: harness.lastError != nil ? .error : .warning
        )
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
                PluginPill(text: plugin.source, color: .secondary)
            }
            .width(90)
            TableColumn("Version") { plugin in
                Text(plugin.version)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(80)
            TableColumn("Status") { plugin in
                PluginPill(text: statusLabel(plugin.runtimeStatus), color: statusColor(plugin.runtimeStatus))
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

    private func statusLabel(_ status: String) -> String {
        status.prefix(1).uppercased() + status.dropFirst()
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "enabled": return .green
        case "inactive": return .orange
        default: return .secondary
        }
    }
}

/// Inline pill following the badge styling used across the Manage surfaces —
/// a tinted, rounded capsule for source / status labels.
private struct PluginPill: View {
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
            Text(plugin.name)
                .font(.headline)
                .textSelection(.enabled)

            HStack(spacing: 6) {
                PluginPill(text: plugin.source, color: .secondary)
                PluginPill(text: plugin.version, color: .secondary)
                PluginPill(text: statusLabel, color: statusColor)
                if !plugin.hasDashboardManifest {
                    PluginPill(text: "No dashboard tab", color: .secondary)
                }
            }

            if !plugin.description.isEmpty {
                Divider()
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

    private var statusLabel: String {
        plugin.runtimeStatus.prefix(1).uppercased() + plugin.runtimeStatus.dropFirst()
    }

    private var statusColor: Color {
        switch plugin.runtimeStatus {
        case "enabled": return .green
        case "inactive": return .orange
        default: return .secondary
        }
    }
}

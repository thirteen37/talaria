import HermesKit
import SwiftUI

struct ToolsView: View {
    let client: DashboardClient?
    let runner: HermesAdminRunning?
    let hermesVersion: HermesVersion?

    @Environment(BannerCenter.self) private var banners: BannerCenter?

    @State private var harness: ToolsMatrixHarness?

    init(client: DashboardClient?, runner: HermesAdminRunning?, hermesVersion: HermesVersion? = nil) {
        self.client = client
        self.runner = runner
        self.hermesVersion = hermesVersion
    }

    var body: some View {
        Group {
            if runner == nil {
                ContentUnavailableView(
                    "Admin runner unavailable",
                    systemImage: "hammer",
                    description: Text("Open a server with a Hermes binary to manage tools.")
                )
            } else if client == nil {
                ContentUnavailableView(
                    "Dashboard not ready",
                    systemImage: "wrench.and.screwdriver",
                    description: Text("Waiting for the Hermes dashboard to come online.")
                )
            } else if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Tools")
        .dismissesBanner("tools", from: banners)
        .task(id: client != nil) {
            guard let client, runner != nil else {
                harness = nil
                return
            }
            if harness != nil { return }
            let h = ToolsMatrixHarness(client: client, runner: runner)
            h.banners = banners
            harness = h
            await h.refresh()
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await harness?.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(harness?.isLoading ?? true)
                .help("Refresh the tools matrix")
            }
        }
    }

    @ViewBuilder
    private func content(harness: ToolsMatrixHarness) -> some View {
        // The config side panel mirrors GatewayView: a resizable `HSplitView` on
        // macOS, an `HStack`+`Divider` on iPad. Selecting a tool's Config button
        // opens the secondary pane; closing it (or losing the tool's last var)
        // collapses the split back to the full-width matrix.
        PlatformSplit(
            showsSecondary: Binding(
                get: { harness.selectedToolID != nil },
                set: { if !$0 { harness.selectedToolID = nil } }
            ),
            secondaryTitle: configTitle(harness)
        ) {
            matrixPane(harness: harness)
                .frame(minWidth: Idiom.isPhone ? nil : 420, maxWidth: .infinity, maxHeight: .infinity)
        } secondary: {
            configPane(harness: harness)
                .frame(minWidth: 320, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Hard errors route to the top-of-window strip; only the capability
        // warning stays in-surface.
        .manageBanner(
            capabilityBanner(
                .toolsEnablePerPlatform,
                feature: "Per-platform tools enable/disable",
                version: hermesVersion
            ),
            severity: .warning
        )
    }

    @ViewBuilder
    private func matrixPane(harness: ToolsMatrixHarness) -> some View {
        if let matrix = harness.matrix {
            if matrix.rows.isEmpty, !harness.isLoading {
                ContentUnavailableView("No tools", systemImage: "hammer")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                matrixGrid(matrix, harness: harness)
            }
        } else if harness.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No tools", systemImage: "hammer")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Title for the pushed iPhone config page — the selected tool's friendly
    /// label (or raw id). nil when nothing is selected (the pane is hidden).
    private func configTitle(_ harness: ToolsMatrixHarness) -> String? {
        guard let toolID = harness.selectedToolID,
              let row = harness.matrix?.rows.first(where: { $0.name == toolID }) else { return nil }
        return row.label ?? row.name
    }

    @ViewBuilder
    private func configPane(harness: ToolsMatrixHarness) -> some View {
        if let toolID = harness.selectedToolID,
           let row = harness.matrix?.rows.first(where: { $0.name == toolID }) {
            ToolConfigEditor(
                tool: row,
                vars: harness.configVars(for: toolID),
                busy: harness.envBusy,
                remaskToken: harness.remaskToken,
                onSave: { key, value in Task { await harness.saveEnv(key: key, value: value) } },
                onDelete: { key in Task { await harness.deleteEnv(key: key) } },
                reveal: { key in await harness.revealEnv(key: key) },
                onClose: { harness.selectedToolID = nil }
            )
        } else {
            // PlatformSplit only renders this when `showsSecondary` is true, so
            // this branch is just a type-checker placeholder.
            Color.clear
        }
    }

    private func matrixGrid(_ matrix: ToolsMatrix, harness: ToolsMatrixHarness) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Tool")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 300, alignment: .leading)
                    ForEach(matrix.platforms, id: \.self) { platform in
                        platformHeader(platform)
                    }
                }

                Rectangle()
                    .fill(.separator)
                    .frame(height: 1)
                    .gridCellColumns(matrix.platforms.count + 1)
                    .gridCellUnsizedAxes(.vertical)

                ForEach(matrix.rows) { row in
                    GridRow {
                        toolLabelCell(row: row, harness: harness)
                            .frame(width: 300, alignment: .leading)

                        ForEach(matrix.platforms, id: \.self) { platform in
                            toolCell(row: row, platform: platform, harness: harness)
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Leading "Tool" cell: the toolset's emoji icon, then its friendly name with
    /// the Config button inline beside it, and the raw id beneath — aligned under
    /// the name (not the icon), since the emoji is peeled out of the label.
    private func toolLabelCell(row: ToolsMatrix.Row, harness: ToolsMatrixHarness) -> some View {
        let parts = toolLabelParts(row)
        return HStack(alignment: .top, spacing: 8) {
            if let icon = parts.icon {
                Text(icon).frame(width: 20, alignment: .center)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(parts.title)
                        .lineLimit(1)
                    if harness.hasConfig(for: row.name) {
                        configButton(row: row, harness: harness)
                    }
                }
                if parts.showsSlug {
                    Text(row.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func configButton(row: ToolsMatrix.Row, harness: ToolsMatrixHarness) -> some View {
        let isOpen = harness.selectedToolID == row.name
        return Button {
            harness.selectedToolID = isOpen ? nil : row.name
        } label: {
            Label("Config", systemImage: "slider.horizontal.3")
                .font(.caption)
                .fontWeight(isOpen ? .semibold : .regular)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Configure \(row.label ?? row.name)")
        .help("Configure environment variables for \(row.label ?? row.name)")
    }

    private func platformHeader(_ platform: String) -> some View {
        HStack(spacing: 6) {
            if let systemImage = platformSystemImage(platform) {
                Image(systemName: systemImage)
            }
            Text(platformDisplayName(platform))
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 112, alignment: .center)
    }

    @ViewBuilder
    private func toolCell(row: ToolsMatrix.Row, platform: String, harness: ToolsMatrixHarness) -> some View {
        if let enabled = row.enabledByPlatform[platform] {
            Toggle("", isOn: Binding(
                get: { enabled },
                set: { newValue in
                    Task {
                        await harness.setEnabled(tool: row.name, platform: platform, enabled: newValue)
                    }
                }
            ))
            .labelsHidden()
            .disabled(!harness.hasRunner || harness.isBusy(tool: row.name, platform: platform))
            .frame(width: 112, alignment: .center)
        } else {
            Image(systemName: "minus")
                .foregroundStyle(.tertiary)
                .frame(width: 112, alignment: .center)
                .help("State unavailable for \(platformDisplayName(platform))")
        }
    }

    private func platformDisplayName(_ platform: String) -> String {
        if platform == "cli" { return "CLI" }
        return MessagingPlatformCatalog.entries.first { $0.statusKey == platform }?.displayName ?? platform
    }

    private func platformSystemImage(_ platform: String) -> String? {
        if platform == "cli" { return "terminal" }
        return MessagingPlatformCatalog.entries.first { $0.statusKey == platform }?.systemImage
    }
}

/// Splits a toolset label like `🔍 Web Search & Scraping` into its leading emoji
/// icon and the title, so the title and the id subtitle can left-align to the
/// same edge (in both the matrix row and the config panel header). Falls back to
/// the raw id (no subtitle) when there's no friendly label.
private func toolLabelParts(_ row: ToolsMatrix.Row) -> (icon: String?, title: String, showsSlug: Bool) {
    guard let label = row.label, !label.isEmpty else {
        return (nil, row.name, false)
    }
    if let first = label.first, first.isEmojiLike {
        let title = String(label.dropFirst()).trimmingCharacters(in: .whitespaces)
        return (String(first), title.isEmpty ? label : title, true)
    }
    return (nil, label, true)
}

private extension Character {
    /// Heuristic for the leading emoji in a Hermes toolset label (`🔍 Title`).
    /// Excludes plain ASCII so a label starting with a letter/digit isn't peeled
    /// as an icon, and accepts both emoji-presentation scalars and emoji that
    /// default to text presentation (e.g. 👁️) by their codepoint range.
    var isEmojiLike: Bool {
        guard let scalar = unicodeScalars.first, !scalar.isASCII else { return false }
        return scalar.properties.isEmojiPresentation
            || (scalar.properties.isEmoji && scalar.value > 0x2300)
    }
}

/// The selected tool's config side panel: a header plus one editable field per
/// env var Hermes links to the tool. The field machinery mirrors GatewayView's
/// `MessagingFieldRow` — env vars are global (not per-platform), so a tool's
/// config is the same regardless of which column was toggled.
private struct ToolConfigEditor: View {
    let tool: ToolsMatrix.Row
    let vars: [DashboardEnvVar]
    let busy: Set<String>
    let remaskToken: Int
    let onSave: (String, String) -> Void
    let onDelete: (String) -> Void
    let reveal: (String) async -> String?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(vars) { envVar in
                        ToolEnvFieldRow(
                            envVar: envVar,
                            busy: busy.contains(envVar.name),
                            remaskToken: remaskToken,
                            onSave: { onSave(envVar.name, $0) },
                            onDelete: { onDelete(envVar.name) },
                            reveal: { await reveal(envVar.name) }
                        )
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Reset every field's typed/revealed draft when switching tools.
        .id(tool.id)
    }

    private var header: some View {
        let parts = toolLabelParts(tool)
        return HStack(spacing: 10) {
            if let icon = parts.icon {
                Text(icon).font(.title3)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(parts.title)
                    .font(.headline)
                    .lineLimit(1)
                if parts.showsSlug {
                    Text(tool.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close")
            .help("Close the config panel")
        }
        .padding()
    }
}

/// One env-var editor in the tool config panel: the var name, a
/// `SecureField`+Reveal (secrets) or plain `TextField` (otherwise), the
/// description/doc-link caption, and per-field Save / Delete. The reveal/draft
/// lifecycle mirrors GatewayView's `MessagingFieldRow`.
private struct ToolEnvFieldRow: View {
    let envVar: DashboardEnvVar
    let busy: Bool
    let remaskToken: Int
    let onSave: (String) -> Void
    let onDelete: () -> Void
    let reveal: () async -> String?

    @State private var draft: String = ""
    @State private var confirmingDelete = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(envVar.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if envVar.isSet {
                    Text("Set")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }

            HStack(spacing: 4) {
                RevealableSecretField(
                    text: $draft,
                    placeholder: placeholder,
                    isSecret: envVar.isPassword,
                    canReveal: envVar.isSet,
                    reveal: reveal,
                    focus: $fieldFocused,
                    remaskToken: remaskToken
                )
                saveButton
                if envVar.isSet { deleteButton }
            }

            caption
        }
        .padding(.vertical, 4)
        // Clear the draft once a save lands: a successful save reloads this var
        // with its new redacted value, firing this change. A failed save doesn't
        // reload, so the user's input is preserved to retry.
        .onChange(of: envVar.redactedValue) { _, _ in
            draft = ""
        }
        .alert("Delete \(envVar.name)?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            Text("This removes the variable from the Hermes host's .env file.")
        }
    }

    /// Placeholder = the current (redacted) value when set, otherwise a hint. An
    /// empty `draft` therefore reads as "keep the current value".
    private var placeholder: String {
        if let redacted = envVar.redactedValue, !redacted.isEmpty {
            return redacted
        }
        return "Value"
    }

    private var saveButton: some View {
        Button {
            onSave(draft)
        } label: {
            Image(systemName: "checkmark.circle")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(fieldFocused ? KeyboardShortcut(.return, modifiers: .command) : nil)
        .disabled(busy || draft.isEmpty)
        .accessibilityLabel("Save")
        .help("Save \(envVar.name)")
    }

    private var deleteButton: some View {
        Button {
            confirmingDelete = true
        } label: {
            Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(busy)
        .accessibilityLabel("Delete")
        .help("Delete \(envVar.name)")
    }

    @ViewBuilder
    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !envVar.description.isEmpty {
                Text(envVar.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let url = envVar.url, let link = URL(string: url) {
                Link(destination: link) {
                    Label(url, systemImage: "link")
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

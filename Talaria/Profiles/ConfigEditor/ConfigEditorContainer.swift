import HermesKit
import SwiftUI

/// Desktop-class container for the profile config editor (macOS + iPad). Hosts a
/// single-profile structured/YAML editor scoped to the window's active Hermes
/// profile, with a Structured⇄YAML segmented toggle, a Save action, and a
/// Compare mode that reveals a second profile picker and switches to the
/// read-only comparison. The primary profile is chosen by the window's
/// top-level switcher, so there's no picker here.
///
/// The compact (iPhone) variant is intentionally not built here — it would reuse
/// `ConfigEditorHarness` + the structured/YAML editors without Compare.
struct ConfigEditorContainer: View {
    let windowHarness: ServerWindowHarness
    /// Profiles available on the server (for the compare dropdown), surfaced by
    /// the window so the editor doesn't re-enumerate them.
    let profiles: [HermesProfileInfo]

    @State private var editor: ConfigEditorHarness?

    var body: some View {
        Group {
            if let editor {
                content(editor)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Configuration")
        .task {
            guard editor == nil else { return }
            let harness = makeEditor()
            editor = harness
            await harness.start()
        }
        // The window's dashboard may come online after the editor first rendered
        // (degraded). Re-load to upgrade to the live form.
        .onChange(of: windowHarness.dashboardClient != nil) { _, hasClient in
            guard hasClient, let editor else { return }
            editor.reloadIfDashboardAppeared()
        }
        // The window's Hermes-profile enumeration can land after the editor
        // opened (a slow remote `profile list`). Feed it in so the Compare
        // dropdown fills instead of staying empty for the editor's lifetime.
        .onChange(of: profiles) { _, newProfiles in
            editor?.setAvailableProfiles(newProfiles)
        }
    }

    private func makeEditor() -> ConfigEditorHarness {
        ConfigEditorHarness(
            profiles: profiles,
            editedProfileName: windowHarness.hermesProfileName,
            defaultClient: { [weak windowHarness] in windowHarness?.dashboardClient },
            profile: windowHarness.profile,
            transfer: windowHarness.snapshotTransfer
        )
    }

    @ViewBuilder
    private func content(_ editor: ConfigEditorHarness) -> some View {
        Group {
            if editor.comparing {
                ProfilesComparisonView(
                    comparison: editor.comparison,
                    sourceName: editor.editedProfileName,
                    destName: editor.compareProfile,
                    showDifferencesOnly: editor.showDifferencesOnly,
                    isLoading: editor.isLoading
                )
            } else {
                switch editor.mode {
                case .structured:
                    StructuredConfigEditor(harness: editor)
                case .yaml:
                    YAMLConfigEditor(harness: editor)
                }
            }
        }
        .toolbar { toolbar(editor) }
        .manageBanner(banner(editor), severity: editor.lastError != nil ? .error : .warning)
    }

    @ToolbarContentBuilder
    private func toolbar(_ editor: ConfigEditorHarness) -> some ToolbarContent {
        ToolbarItemGroup {
            if !editor.comparing {
                Picker("View", selection: Binding(
                    get: { editor.mode },
                    set: { editor.setMode($0) }
                )) {
                    ForEach(ConfigEditorHarness.Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(editor.dashboardUnavailable)
            }

            Button {
                editor.toggleComparing()
            } label: {
                Label("Compare", systemImage: editor.comparing ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
            }

            if editor.comparing {
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Picker("Compare with", selection: Binding(
                    get: { editor.compareProfile },
                    set: { editor.setCompareProfile($0) }
                )) {
                    ForEach(editor.profiles.filter { $0.name != editor.editedProfileName }) {
                        Text($0.name).tag($0.name)
                    }
                }
                Toggle("Differences only", isOn: Binding(
                    get: { editor.showDifferencesOnly },
                    set: { editor.showDifferencesOnly = $0 }
                ))
            } else {
                Button {
                    Task { await editor.save() }
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .disabled(!editor.canSave)
            }

            Button {
                Task { await editor.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(editor.isLoading)
        }
    }

    private func banner(_ editor: ConfigEditorHarness) -> String? {
        if let error = editor.lastError { return error }
        if editor.dashboardUnavailable {
            return "Dashboard unavailable — showing the on-disk config read-only. Save is disabled."
        }
        return nil
    }
}

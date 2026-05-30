import HermesKit
import SwiftUI

/// Desktop-class container for the profile config editor (macOS + iPad). Hosts a
/// single-profile structured/YAML editor with a toolbar profile picker, a
/// Structured⇄YAML segmented toggle, a Save action, and a Compare mode that
/// reveals a second profile picker and switches to the read-only comparison.
///
/// The compact (iPhone) variant is intentionally not built here — it would reuse
/// `ConfigEditorHarness` + the structured/YAML editors without Compare.
struct ConfigEditorContainer: View {
    let windowHarness: ServerWindowHarness

    @State private var editor: ConfigEditorHarness?

    var body: some View {
        Group {
            if let editor {
                content(editor)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Profiles")
        .task {
            guard editor == nil else { return }
            let harness = makeEditor()
            editor = harness
            await harness.start()
        }
        // The window's default dashboard may come online after the editor first
        // rendered (degraded). Re-load to upgrade to the live form.
        .onChange(of: windowHarness.dashboardClient != nil) { _, hasClient in
            guard hasClient, let editor else { return }
            editor.reloadIfDashboardAppeared()
        }
        .onDisappear {
            let harness = editor
            Task { await harness?.teardown() }
        }
    }

    private func makeEditor() -> ConfigEditorHarness {
        ConfigEditorHarness(
            defaultClient: { [weak windowHarness] in windowHarness?.dashboardClient },
            runner: windowHarness.store.adminRunner,
            profile: windowHarness.profile,
            transfer: windowHarness.snapshotTransfer,
            acquireScoped: { name in
                try await windowHarness.acquireScopedDashboardClient(hermesProfileName: name)
            },
            releaseScoped: { supervisor in
                await windowHarness.releaseScopedDashboard(supervisor)
            }
        )
    }

    @ViewBuilder
    private func content(_ editor: ConfigEditorHarness) -> some View {
        Group {
            if editor.comparing {
                ProfilesComparisonView(
                    comparison: editor.comparison,
                    sourceName: editor.selectedProfile,
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
            Picker("Profile", selection: Binding(
                get: { editor.selectedProfile },
                set: { name in Task { await editor.selectProfile(name) } }
            )) {
                ForEach(editor.profiles) { Text($0.name).tag($0.name) }
            }

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
                    ForEach(editor.profiles.filter { $0.name != editor.selectedProfile }) {
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
        if editor.profilesUnavailable {
            return "Profile listing is unavailable in this Hermes version."
        }
        return nil
    }
}

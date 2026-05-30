import HermesKit
import SwiftUI

/// Container for the Configuration editor. Hosts a structured/YAML editor for the
/// window's active Hermes profile (no in-editor picker — the primary profile is
/// chosen by the window's top-level switcher), a Structured⇄YAML segmented
/// toggle, a Save action, and (desktop only) a Compare mode that reveals a second
/// profile picker and the editable two-column comparison.
///
/// The same container backs both the desktop window and the iPhone Browse sheet
/// (`BrowseDetailView` → `PhoneBrowseSheet`); Compare is gated off on iPhone,
/// where the two-column layout is unusable.
struct ConfigEditorContainer: View {
    let windowHarness: ServerWindowHarness
    /// Profiles available on the server (for the compare dropdown), surfaced by
    /// the window so the editor doesn't re-enumerate them.
    let profiles: [HermesProfileInfo]

    @State private var editor: ConfigEditorHarness?

    /// Compare needs the room a desktop split has and at least two profiles to
    /// line up. iPhone reuses this container without it.
    private func canCompare(_ editor: ConfigEditorHarness) -> Bool {
        !Idiom.isPhone && editor.profiles.count >= 2
    }

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
        // Release every scoped dashboard the editor acquired (Compare spawns a
        // live SSH/dashboard connection per compared profile) when the view goes
        // away — navigating to another Browse destination, dismissing the iPhone
        // Browse sheet, or the window rebuilding on a profile switch.
        .onDisappear {
            let harness = editor
            Task { await harness?.teardown() }
        }
    }

    private func makeEditor() -> ConfigEditorHarness {
        ConfigEditorHarness(
            profiles: profiles,
            editedProfileName: windowHarness.hermesProfileName,
            defaultClient: { [weak windowHarness] in windowHarness?.dashboardClient },
            profile: windowHarness.profile,
            transfer: windowHarness.snapshotTransfer,
            // Comparison reaches a profile other than the window's active one, so
            // it acquires that profile's own scoped dashboard.
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
            if editor.comparing, let dest = editor.dest {
                EditableComparisonView(source: editor.source, dest: dest)
            } else {
                switch editor.source.mode {
                case .structured:
                    StructuredConfigEditor(state: editor.source)
                case .yaml:
                    YAMLConfigEditor(state: editor.source)
                }
            }
        }
        .toolbar { toolbar(editor) }
        .manageBanner(banner(editor), severity: editor.source.lastError != nil || editor.lastError != nil ? .error : .warning)
    }

    @ToolbarContentBuilder
    private func toolbar(_ editor: ConfigEditorHarness) -> some ToolbarContent {
        ToolbarItemGroup {
            if !editor.comparing {
                Picker("View", selection: Binding(
                    get: { editor.source.mode },
                    set: { editor.setMode($0) }
                )) {
                    ForEach(ConfigEditorHarness.Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(editor.source.dashboardUnavailable)
            }

            if canCompare(editor) {
                Button {
                    editor.toggleComparing()
                } label: {
                    Label("Compare", systemImage: editor.comparing ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
                }
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
            } else {
                Button {
                    Task { await editor.source.save() }
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .disabled(!editor.source.canSave)
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
        if let error = editor.source.lastError { return error }
        if let error = editor.lastError { return error }
        if editor.source.dashboardUnavailable {
            return "Dashboard unavailable — showing the on-disk config read-only. Save is disabled."
        }
        return nil
    }
}

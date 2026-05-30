import HermesKit
import SwiftUI

/// Container for the profile config editor. Hosts a single-profile
/// structured/YAML editor with a toolbar profile picker, a Structured⇄YAML
/// segmented toggle, a Save action, and (desktop only) a Compare mode that
/// reveals a second profile picker and the editable two-column comparison.
///
/// The same container backs both the desktop window and the iPhone Browse sheet
/// (`BrowseDetailView` → `PhoneBrowseSheet`); Compare is gated off on iPhone,
/// where the two-column layout is unusable.
struct ConfigEditorContainer: View {
    let windowHarness: ServerWindowHarness

    @State private var editor: ConfigEditorHarness?
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var pendingRestoreText: String?

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
        .fileExporter(isPresented: $showingExporter,
                      document: YAMLFileDocument(text: editor.source.backupYAML),
                      contentType: .hermesYAML,
                      defaultFilename: editor.source.backupFilename) { result in
            if case .failure(let e) = result { editor.source.lastError = e.localizedDescription }
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.hermesYAML, .text, .data]) { result in
            switch result {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { pendingRestoreText = try String(contentsOf: url, encoding: .utf8) }
                catch { editor.source.lastError = error.localizedDescription }
            case .failure(let e):
                editor.source.lastError = e.localizedDescription
            }
        }
        .alert("Replace live config?", isPresented: Binding(
                get: { pendingRestoreText != nil },
                set: { if !$0 { pendingRestoreText = nil } })) {
            Button("Replace", role: .destructive) {
                if let text = pendingRestoreText { Task { await editor.source.restore(fromYAML: text) } }
                pendingRestoreText = nil
            }
            Button("Cancel", role: .cancel) { pendingRestoreText = nil }
        } message: {
            Text("This overwrites the saved config for “\(editor.selectedProfile)” with the imported file.")
        }
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
                    ForEach(editor.profiles.filter { $0.name != editor.selectedProfile }) {
                        Text($0.name).tag($0.name)
                    }
                }
            } else {
                Button { showingExporter = true } label: {
                    Label("Download", systemImage: "square.and.arrow.down")
                }
                .disabled(!editor.source.canExportBackup)

                Button { showingImporter = true } label: {
                    Label("Upload", systemImage: "square.and.arrow.up")
                }
                .disabled(editor.source.dashboardUnavailable || editor.isLoading)

                Button {
                    Task { await editor.source.save() }
                } label: {
                    Label("Save", systemImage: "checkmark.circle")
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
        if editor.profilesUnavailable {
            return "Profile listing is unavailable in this Hermes version."
        }
        return nil
    }
}

import HermesKit
import SwiftUI

struct SoulEditorContainer: View {
    let windowHarness: ServerWindowHarness

    @State private var editor: SoulEditingState?

    var body: some View {
        Group {
            if let editor {
                content(editor)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Soul")
        .task {
            guard editor == nil else { return }
            let state = makeEditor()
            editor = state
            state.load()
        }
        .onChange(of: windowHarness.dashboardClient != nil) { _, hasClient in
            guard hasClient else { return }
            editor?.reloadIfDashboardAppeared()
        }
        .onDisappear {
            let state = editor
            Task { await state?.teardown() }
        }
    }

    private func makeEditor() -> SoulEditingState {
        SoulEditingState(
            profileName: windowHarness.hermesProfileName,
            defaultClient: { [weak windowHarness] in windowHarness?.dashboardClient },
            serverProfile: windowHarness.profile,
            transfer: windowHarness.snapshotTransfer
        )
    }

    @ViewBuilder
    private func content(_ editor: SoulEditingState) -> some View {
        soulTextView(editor)
            .toolbar { toolbar(editor) }
            .manageBanner(banner(editor), severity: editor.lastError != nil ? .error : .warning)
    }

    @ViewBuilder
    private func soulTextView(_ editor: SoulEditingState) -> some View {
        if editor.dashboardUnavailable {
            ScrollView {
                Text(editor.text.isEmpty ? "No SOUL.md available." : editor.text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
        } else {
            TextEditor(text: Binding(
                get: { editor.text },
                set: { editor.text = $0 }
            ))
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .padding(4)
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ editor: SoulEditingState) -> some ToolbarContent {
        ToolbarItemGroup {
            Button {
                Task { await editor.save() }
            } label: {
                Label("Save", systemImage: "checkmark.circle")
            }
            .disabled(!editor.canSave)
            .help("Save SOUL.md")

            Button {
                editor.load()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(editor.isLoading)
            .help("Reload SOUL.md from disk")
        }
    }

    private func banner(_ editor: SoulEditingState) -> String? {
        if let error = editor.lastError { return error }
        if editor.dashboardUnavailable {
            return "Dashboard unavailable - showing the on-disk SOUL.md read-only. Save is disabled."
        }
        return nil
    }
}

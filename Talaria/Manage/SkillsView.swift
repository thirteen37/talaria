import HermesKit
import SwiftUI

struct SkillsView: View {
    let runner: HermesAdminRunning?

    @State private var harness: ManageListHarness<SkillRow>?
    @State private var preview: String?
    @State private var previewError: String?
    @State private var loadingPreview = false
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        Group {
            if runner == nil {
                ContentUnavailableView(
                    "Admin runner unavailable",
                    systemImage: "wand.and.stars",
                    description: Text("Open a profile with a Hermes binary to manage skills.")
                )
            } else if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Skills")
        .task {
            if runner == nil {
                harness = nil
                return
            }
            if harness != nil { return }
            let h = ManageListHarness<SkillRow>(
                runner: runner,
                lister: { try await HermesSkills.list(runner: $0) },
                toggler: { runner, row, enabled in
                    if enabled {
                        try await HermesSkills.enable(runner: runner, name: row.name)
                    } else {
                        try await HermesSkills.disable(runner: runner, name: row.name)
                    }
                }
            )
            harness = h
            await h.refresh()
        }
    }

    @ViewBuilder
    private func content(harness: ManageListHarness<SkillRow>) -> some View {
        VStack(spacing: 0) {
            HSplitView {
                Table(harness.rows, selection: Binding(get: { harness.selectionID }, set: { harness.selectionID = $0 })) {
                    TableColumn("Name") { row in
                        Text(row.name)
                    }
                    TableColumn("Enabled") { row in
                        Toggle("", isOn: Binding(
                            get: { row.enabled },
                            set: { newValue in
                                Task { await harness.setEnabled(row, enabled: newValue) }
                            }
                        ))
                        .labelsHidden()
                    }
                    .width(80)
                    TableColumn("Path") { row in
                        Text(row.path ?? "")
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

                previewPane(harness: harness)
                    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await harness.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(harness.isLoading)
            }
        }
        .onChange(of: harness.selectionID) { _, newValue in
            loadPreview(for: newValue, harness: harness)
        }
        .manageBanner(harness.lastError)
    }

    @ViewBuilder
    private func previewPane(harness: ManageListHarness<SkillRow>) -> some View {
        if loadingPreview {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let previewError {
            ContentUnavailableView("Couldn't load preview", systemImage: "exclamationmark.triangle", description: Text(previewError))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let preview, !preview.isEmpty {
            ScrollView {
                MarkdownText(text: preview)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Select a skill", systemImage: "sidebar.right")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadPreview(for id: SkillRow.ID?, harness: ManageListHarness<SkillRow>) {
        // Cancel any in-flight load so an older `show` response can't land
        // after a newer one and overwrite the visible preview.
        previewTask?.cancel()
        preview = nil
        previewError = nil
        guard let id, let runner else {
            previewTask = nil
            loadingPreview = false
            return
        }
        loadingPreview = true
        previewTask = Task {
            defer { loadingPreview = false }
            do {
                let body = try await HermesSkills.show(runner: runner, name: id)
                // Belt-and-braces: even if cancellation lost the race, only
                // apply the result when the selection is still on this row.
                guard !Task.isCancelled, harness.selectionID == id else { return }
                preview = body
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, harness.selectionID == id else { return }
                previewError = error.localizedDescription
            }
        }
    }
}

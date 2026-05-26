import HermesKit
import SwiftUI

struct ToolsView: View {
    let runner: HermesAdminRunning?
    let hermesVersion: HermesVersion?

    @State private var harness: ManageListHarness<ToolRow>?

    init(runner: HermesAdminRunning?, hermesVersion: HermesVersion? = nil) {
        self.runner = runner
        self.hermesVersion = hermesVersion
    }

    var body: some View {
        Group {
            if runner == nil {
                ContentUnavailableView(
                    "Admin runner unavailable",
                    systemImage: "hammer",
                    description: Text("Open a profile with a Hermes binary to manage tools.")
                )
            } else if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Tools")
        .task {
            if runner == nil {
                harness = nil
                return
            }
            if harness != nil { return }
            let h = ManageListHarness<ToolRow>(
                runner: runner,
                lister: { try await HermesTools.list(runner: $0) },
                toggler: { runner, row, enabled in
                    if enabled {
                        try await HermesTools.enable(runner: runner, name: row.name)
                    } else {
                        try await HermesTools.disable(runner: runner, name: row.name)
                    }
                }
            )
            harness = h
            await h.refresh()
        }
    }

    @ViewBuilder
    private func content(harness: ManageListHarness<ToolRow>) -> some View {
        VStack(spacing: 0) {
            Table(harness.rows) {
                TableColumn("Name") { row in Text(row.name) }
                TableColumn("Platform") { row in
                    Text(row.platform ?? "")
                        .foregroundStyle(.secondary)
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
            }
            .overlay {
                if harness.rows.isEmpty, !harness.isLoading {
                    ContentUnavailableView("No tools", systemImage: "hammer")
                }
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
        .manageBanner(
            harness.lastError ?? capabilityBanner(
                .toolsEnablePerPlatform,
                feature: "Per-platform tools enable/disable",
                version: hermesVersion
            ),
            severity: harness.lastError != nil ? .error : .warning
        )
    }
}

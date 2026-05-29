import HermesKit
import SwiftUI

@MainActor
@Observable
final class SkillsHarness {
    var rows: [DashboardSkill] = []
    var isLoading: Bool = false
    var lastError: String?
    var selectionID: String?
    var toggling: Set<String> = []

    private let client: DashboardClient

    init(client: DashboardClient) {
        self.client = client
    }

    var selected: DashboardSkill? {
        guard let id = selectionID else { return nil }
        return rows.first(where: { $0.name == id })
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            rows = try await client.listSkills()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setEnabled(_ name: String, enabled: Bool) async {
        toggling.insert(name)
        defer { toggling.remove(name) }
        do {
            try await client.toggleSkill(name: name, enabled: enabled)
            // Refresh so the row reflects what the server actually persisted —
            // dashboard returns 200 on toggle without a body, so we read back.
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

struct SkillsView: View {
    let client: DashboardClient?
    let hermesVersion: HermesVersion?

    @State private var harness: SkillsHarness?

    init(client: DashboardClient?, hermesVersion: HermesVersion? = nil) {
        self.client = client
        self.hermesVersion = hermesVersion
    }

    var body: some View {
        Group {
            if client == nil {
                ContentUnavailableView(
                    "Dashboard not ready",
                    systemImage: "wand.and.stars",
                    description: Text("Waiting for the Hermes dashboard to come online.")
                )
            } else if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Skills")
        // Keyed on client availability so the harness is built when the
        // dashboard finishes booting and `client` flips non-nil, not only on
        // first appear (a bare `.task` on the Group never re-runs for that flip).
        .task(id: client != nil) {
            guard let client else { harness = nil; return }
            if harness != nil { return }
            let h = SkillsHarness(client: client)
            harness = h
            await h.refresh()
        }
    }

    @ViewBuilder
    private func content(harness: SkillsHarness) -> some View {
        HSplitView {
            Table(harness.rows, selection: Binding(
                get: { harness.selectionID },
                set: { harness.selectionID = $0 }
            )) {
                TableColumn("Name") { row in
                    Text(row.name)
                }
                TableColumn("Enabled") { row in
                    Toggle("", isOn: Binding(
                        get: { row.enabled },
                        set: { newValue in
                            Task { await harness.setEnabled(row.name, enabled: newValue) }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(harness.toggling.contains(row.name))
                }
                .width(70)
                TableColumn("Category") { row in
                    Text(row.category ?? "")
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
            .id(harness.rows.map(\.name).joined())

            previewPane(harness: harness)
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
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
                .requiresDashboard,
                feature: "Skills via Hermes dashboard",
                version: hermesVersion
            ),
            severity: harness.lastError != nil ? .error : .warning
        )
    }

    @ViewBuilder
    private func previewPane(harness: SkillsHarness) -> some View {
        if let skill = harness.selected {
            VStack(alignment: .leading, spacing: 8) {
                Text(skill.name)
                    .font(.headline)
                HStack(spacing: 8) {
                    Image(systemName: skill.enabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(skill.enabled ? .green : .secondary)
                    Text(skill.enabled ? "Enabled" : "Disabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let category = skill.category, !category.isEmpty {
                        Text("· \(category)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let description = skill.description, !description.isEmpty {
                    Divider()
                    Text(description)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView("Select a skill", systemImage: "sidebar.right")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

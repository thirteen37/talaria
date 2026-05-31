import HermesKit
import SwiftUI

/// Secondary-pane create form for a new task. Mirrors the Cron `DraftJobEditor`:
/// edits a `KanbanDraft` binding and reports save/cancel up to the harness.
struct KanbanTaskCreatePane: View {
    @Binding var draft: KanbanDraft
    let assignees: [String]
    let onSave: (KanbanDraft) -> Void
    let onCancel: () -> Void

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            Section("New task") {
                TextField("Title", text: $draft.title)
                TextField("Body", text: $draft.body, axis: .vertical)
                    .lineLimit(3...8)
                assigneeField
                Stepper(value: $draft.priority, in: 0...9) {
                    LabeledContent("Priority", value: "\(draft.priority)")
                }
                TextField("Tenant (optional)", text: $draft.tenant)
                Picker("Workspace", selection: $draft.workspaceKind) {
                    ForEach(kanbanWorkspaceKinds, id: \.self) { kind in
                        Text(kanbanStatusTitle(kind)).tag(kind)
                    }
                }
                Toggle("Send to triage", isOn: $draft.triage)
            }
            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button("Add") { onSave(draft) }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canSave)
            }
        }
    }

    @ViewBuilder
    private var assigneeField: some View {
        if assignees.isEmpty {
            TextField("Assignee (optional)", text: $draft.assignee)
        } else {
            Picker("Assignee", selection: $draft.assignee) {
                Text("Unassigned").tag("")
                ForEach(assignees, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
        }
    }
}

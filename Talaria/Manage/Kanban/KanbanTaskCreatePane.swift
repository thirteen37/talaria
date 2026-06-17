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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                KanbanSection {
                    KanbanFieldRow("Title") {
                        TextField("", text: $draft.title)
                    }
                    KanbanFieldRow("Body") {
                        TextField("", text: $draft.body, axis: .vertical)
                            .lineLimit(3...8)
                    }
                    assigneeField
                    KanbanFieldRow("Priority") {
                        Stepper("\(draft.priority)", value: $draft.priority, in: 0...9)
                            .accessibilityValue("\(draft.priority)")
                    }
                    KanbanFieldRow("Tenant (optional)") {
                        TextField("", text: $draft.tenant)
                    }
                    KanbanFieldRow("Workspace") {
                        Picker("", selection: $draft.workspaceKind) {
                            ForEach(kanbanWorkspaceKinds, id: \.self) { kind in
                                Text(kanbanStatusTitle(kind)).tag(kind)
                            }
                        }
                        .labelsHidden()
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
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private var assigneeField: some View {
        KanbanFieldRow("Assignee (optional)") {
            if assignees.isEmpty {
                TextField("", text: $draft.assignee)
            } else {
                Picker("", selection: $draft.assignee) {
                    Text("Unassigned").tag("")
                    ForEach(assignees, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
            }
        }
    }
}

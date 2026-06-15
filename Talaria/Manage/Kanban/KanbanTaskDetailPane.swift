import HermesKit
import SwiftUI

/// Secondary-pane editor for the selected task: editable core fields + a Save
/// button, then read/append surfaces for comments, dependency links, and runs.
/// The editable fields seed from the authoritative `/tasks/{id}` detail payload
/// (`harness.taskDetail`) once it loads, with the partial board summary `card`
/// as the initial placeholder — see `applySeed()`. Seeding is driven by
/// `.onChange` rather than `.id(card.id)`, which would hand the pane a fresh
/// identity and collapse the surrounding `HSplitView` divider back to its
/// minimum width on every card switch.
struct KanbanTaskDetailPane: View {
    let harness: KanbanHarness
    let card: KanbanCard

    @State private var title: String = ""
    @State private var body_: String = ""
    @State private var assignee: String = ""
    @State private var priority: Int = 0
    @State private var status: String = ""

    @State private var newComment: String = ""
    @State private var newParentID: String = ""
    @State private var newChildID: String = ""
    @State private var showDeleteConfirm = false
    @State private var logText: String?
    @State private var isLoadingLog = false
    /// Set while a manual detail-load retry is in flight, so the pane shows
    /// "Loading…" instead of the failure state during the re-fetch.
    @State private var isRetryingDetail = false
    /// The `card.id` whose authoritative `/tasks/{id}` payload has already been
    /// seeded into the editable fields, so a later detail reload (from posting a
    /// comment or editing a link) doesn't clobber in-progress edits.
    @State private var seededDetailID: String?
    /// The exact board-card values the fields were placeholder-seeded from. The
    /// first detail seed only overwrites a field still equal to its placeholder,
    /// so an edit typed during the detail-load window survives.
    @State private var placeholderCard: KanbanCard?

    private var detail: KanbanTaskDetail? { harness.taskDetail }

    /// Authoritative field source once the `/tasks/{id}` detail has loaded for
    /// this card; the board summary `card` is only a partial/stale placeholder
    /// (it can carry `body == nil` or a stale assignee). Editing + Save sends
    /// every non-nil field, so the baseline — what we seed from and diff against
    /// — must be the full detail payload, never the board card.
    private var baseline: KanbanCard {
        if let task = harness.taskDetail?.task, task.id == card.id { return task }
        return card
    }

    private var availableStatuses: [String] {
        let fromBoard = harness.board?.columns.map(\.name) ?? []
        return fromBoard.isEmpty ? kanbanStatusOrder : fromBoard
    }

    /// True once the authoritative `/tasks/{id}` payload has been seeded for
    /// this card. Until then the fields hold the partial board placeholder, so
    /// saving is blocked — a `PATCH` from the placeholder would send `body == ""`
    /// for any card whose summary omits the body and silently clear it server-side.
    private var detailLoaded: Bool { seededDetailID == card.id }

    /// The authoritative detail fetch for this card failed and no retry is in
    /// flight — show the failure + Retry affordance rather than a stuck spinner.
    private var detailFailed: Bool { harness.detailLoadFailedID == card.id && !isRetryingDetail }

    private var saveDisabled: Bool {
        !detailLoaded
            || title.trimmingCharacters(in: .whitespaces).isEmpty
            || !hasEdits
    }

    private var hasEdits: Bool {
        title != baseline.title
            || body_ != (baseline.body ?? "")
            || assignee != (baseline.assignee ?? "")
            || priority != (baseline.priority ?? 0)
            || status != baseline.status
    }

    var body: some View {
        Form {
            editorSection
            if let warnings = card.warnings, let count = warnings.count, count > 0 {
                warningsSection(warnings)
            }
            if let diagnostics = card.diagnostics, !diagnostics.isEmpty {
                diagnosticsSection(diagnostics)
            }
            commentsSection
            linksSection
            runsSection
        }
        .onAppear { resetTransient(); applySeed() }
        .onChange(of: card.id) { _, _ in
            seededDetailID = nil
            resetTransient()
            applySeed()
        }
        // Re-seed once the authoritative detail payload arrives for this card.
        .onChange(of: harness.taskDetail?.task) { _, _ in applySeed() }
        // After the first seed, follow server-routed status changes — a Save or
        // a drag-move the server lands in a different column than requested (e.g.
        // a promotion into `done`). The picker's own selection changes `status`
        // but not `baseline.status`, so this only fires for an authoritative
        // change, never for an in-progress user pick — clearing the phantom edit
        // that would otherwise re-enable Save with the stale requested status.
        .onChange(of: baseline.status) { _, newStatus in
            if detailLoaded { status = newStatus }
        }
        .alert("Delete task?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task { await harness.deleteTask(id: card.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(card.title)” will be permanently removed.")
        }
    }

    /// Seeds the editable fields. Until the authoritative `/tasks/{id}` payload
    /// loads, fields show the partial board card as a placeholder (Save stays
    /// disabled via `detailLoaded`). The first detail seed merges per-field —
    /// overwriting only fields still equal to their placeholder — so an edit
    /// typed during the load window survives, while a later reload (comment/link)
    /// is skipped entirely by the `seededDetailID` guard.
    private func applySeed() {
        guard let task = harness.taskDetail?.task, task.id == card.id else {
            // Detail not loaded yet — placeholder-seed once.
            if seededDetailID != card.id {
                seedFields(from: card)
                placeholderCard = card
            }
            return
        }
        guard seededDetailID != card.id else { return }
        let placeholder = placeholderCard ?? card
        if title == placeholder.title { title = task.title }
        if body_ == (placeholder.body ?? "") { body_ = task.body ?? "" }
        if assignee == (placeholder.assignee ?? "") { assignee = task.assignee ?? "" }
        if priority == (placeholder.priority ?? 0) { priority = task.priority ?? 0 }
        if status == placeholder.status { status = task.status }
        seededDetailID = card.id
    }

    private func seedFields(from source: KanbanCard) {
        title = source.title
        body_ = source.body ?? ""
        assignee = source.assignee ?? ""
        priority = source.priority ?? 0
        status = source.status
    }

    /// Resets transient per-card state the (now-removed) `.id(card.id)` used to
    /// clear, so a card switch doesn't carry over a draft comment/link, a stale
    /// log, or an open delete confirmation.
    private func resetTransient() {
        newComment = ""
        newParentID = ""
        newChildID = ""
        showDeleteConfirm = false
        logText = nil
        isLoadingLog = false
        isRetryingDetail = false
    }

    /// Re-fetches the authoritative detail after a transient load failure. The
    /// poll never reloads detail by design, so this manual retry is the in-pane
    /// recovery path.
    private func retryDetail() {
        isRetryingDetail = true
        Task {
            await harness.loadDetail(id: card.id)
            isRetryingDetail = false
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private var editorSection: some View {
        Section {
            LabeledContent("ID") {
                Text(card.id).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            TextField("Title", text: $title)
            TextField("Body", text: $body_, axis: .vertical).lineLimit(3...10)
            assigneeField
            Stepper(value: $priority, in: 0...9) {
                LabeledContent("Priority", value: "\(priority)")
            }
            Picker("Status", selection: $status) {
                ForEach(availableStatuses, id: \.self) { name in
                    Text(kanbanStatusTitle(name)).tag(name)
                }
            }
            if !detailLoaded {
                if detailFailed {
                    HStack(spacing: 8) {
                        Label("Couldn't load full task details — editing is disabled.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Retry") { retryDetail() }
                            .font(.caption)
                            .help("Reload this task's details")
                    }
                } else {
                    Label("Loading full task details… editing is disabled until they load.", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Label("Delete", systemImage: "trash")
                }
                Spacer()
                Button("Save") {
                    Task {
                        await harness.updateTask(
                            id: card.id,
                            title: title,
                            // Send body/assignee only when changed from the
                            // authoritative baseline. Otherwise an unrelated edit
                            // (e.g. title-only) on a task whose body/assignee is
                            // empty would PATCH `""`, persisting an empty string
                            // where the server had null. A deliberate clear still
                            // sends `""` (the change is real), so unassigning via
                            // the "Unassigned" picker keeps working.
                            body: body_ != (baseline.body ?? "") ? body_ : nil,
                            assignee: assignee != (baseline.assignee ?? "") ? assignee : nil,
                            priority: priority,
                            // Only PATCH the status when it actually changed —
                            // re-sending the current status would re-trigger the
                            // server-side transition routing on an unrelated edit.
                            status: status != baseline.status ? status : nil
                        )
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(saveDisabled)
            }
        }
    }

    @ViewBuilder
    private var assigneeField: some View {
        let assignees = harness.board?.assignees ?? []
        if assignees.isEmpty {
            TextField("Assignee", text: $assignee)
        } else {
            Picker("Assignee", selection: $assignee) {
                Text("Unassigned").tag("")
                ForEach(assignees, id: \.self) { name in Text(name).tag(name) }
                if !assignee.isEmpty, !assignees.contains(assignee) {
                    Text(assignee).tag(assignee)
                }
            }
        }
    }

    // MARK: - Callouts

    private func warningsSection(_ warnings: KanbanWarnings) -> some View {
        Section("Warnings") {
            ForEach(Array((warnings.kinds ?? [:]).sorted(by: { $0.key < $1.key })), id: \.key) { kind, count in
                Label("\(kanbanStatusTitle(kind)): \(count)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
    }

    private func diagnosticsSection(_ diagnostics: [KanbanDiagnostic]) -> some View {
        Section("Diagnostics") {
            ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diag in
                VStack(alignment: .leading, spacing: 2) {
                    Label(diag.message ?? diag.kind ?? "Diagnostic", systemImage: "stethoscope")
                        .font(.caption.weight(.medium))
                    if let severity = diag.severity {
                        Text("\(severity)\(diag.count.map { " ×\($0)" } ?? "")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Comments

    @ViewBuilder
    private var commentsSection: some View {
        Section("Comments") {
            if let comments = detail?.comments, !comments.isEmpty {
                ForEach(comments) { comment in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(comment.author ?? "—").font(.caption.weight(.semibold))
                        Text(comment.body).font(.callout)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if detailFailed {
                Button("Retry loading comments") { retryDetail() }
                    .font(.caption)
            } else if detail == nil {
                ProgressView().controlSize(.small)
            } else {
                Text("No comments yet.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Add a comment", text: $newComment, axis: .vertical).lineLimit(1...4)
                Button("Post") {
                    let text = newComment
                    Task {
                        if await harness.addComment(taskId: card.id, body: text) {
                            newComment = ""
                        }
                    }
                }
                .disabled(newComment.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Links

    @ViewBuilder
    private var linksSection: some View {
        Section("Dependencies") {
            linkList(
                title: "Parents",
                singular: "parent",
                ids: detail?.links.parents ?? [],
                onRemove: { parent in
                    Task { await harness.unlink(parentId: parent, childId: card.id, anchorId: card.id) }
                }
            )
            HStack {
                TextField("Add parent task id", text: $newParentID)
                Button("Link") {
                    let parent = newParentID.trimmingCharacters(in: .whitespaces)
                    Task {
                        if await harness.linkParent(parentId: parent, to: card.id) {
                            newParentID = ""
                        }
                    }
                }
                .disabled(newParentID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            linkList(
                title: "Children",
                singular: "child",
                ids: detail?.links.children ?? [],
                onRemove: { child in
                    Task { await harness.unlink(parentId: card.id, childId: child, anchorId: card.id) }
                }
            )
            HStack {
                TextField("Add child task id", text: $newChildID)
                Button("Link") {
                    let child = newChildID.trimmingCharacters(in: .whitespaces)
                    Task {
                        if await harness.linkChild(childId: child, of: card.id) {
                            newChildID = ""
                        }
                    }
                }
                .disabled(newChildID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    @ViewBuilder
    private func linkList(
        title: String,
        singular: String,
        ids: [String],
        onRemove: @escaping (String) -> Void
    ) -> some View {
        if ids.isEmpty {
            LabeledContent(title) { Text("None").foregroundStyle(.secondary) }
        } else {
            ForEach(ids, id: \.self) { id in
                HStack {
                    Text(id).font(.system(.callout, design: .monospaced))
                    Spacer()
                    Button(role: .destructive) { onRemove(id) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this \(singular) link")
                }
            }
        }
    }

    // MARK: - Runs

    @ViewBuilder
    private var runsSection: some View {
        Section("Runs") {
            if let runs = detail?.runs, !runs.isEmpty {
                ForEach(runs) { run in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Run \(run.id)").font(.caption.weight(.semibold))
                            if let status = run.status { Text(status).font(.caption2).foregroundStyle(.secondary) }
                            if let outcome = run.outcome {
                                Text(outcome)
                                    .font(.caption2)
                                    .foregroundStyle(outcome == "success" ? .green : .orange)
                            }
                        }
                        if let summary = run.summary { Text(summary).font(.caption) }
                        if let error = run.error {
                            Text(error).font(.caption2).foregroundStyle(.red).lineLimit(3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No runs.").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task {
                    isLoadingLog = true
                    logText = await harness.taskLog(id: card.id)
                    isLoadingLog = false
                }
            } label: {
                Label(isLoadingLog ? "Loading log…" : "Show log", systemImage: "doc.text")
            }
            .disabled(isLoadingLog)
            if let logText {
                ScrollView {
                    Text(logText.isEmpty ? "Log is empty." : logText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
        }
    }
}

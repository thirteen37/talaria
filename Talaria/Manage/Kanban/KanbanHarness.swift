import Foundation
import HermesKit

/// Create-form draft for a new task. Mirrors `CronDraft` / `ProfileDraft` —
/// a plain value the secondary pane edits through a binding.
struct KanbanDraft: Equatable {
    var title: String = ""
    var body: String = ""
    var assignee: String = ""
    var priority: Int = 0
    var tenant: String = ""
    var triage: Bool = false
    var workspaceKind: String = "scratch"
}

/// Canonical lifecycle column order. Used by the iPhone status picker and as the
/// move-target list; the desktop board renders whatever columns the server
/// returns (which follow this same order).
let kanbanStatusOrder = ["triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done"]

/// Workspace kinds accepted by `POST /tasks` (`CreateTaskBody` default + CLI
/// choices).
let kanbanWorkspaceKinds = ["scratch", "dir", "worktree"]

/// View-model for the Kanban Browse surface. Owns board/boards/detail state,
/// optimistic drag handling, and every mutation. The view drives polling via a
/// `.task(id:)` that calls ``refresh()`` on a timer — the harness itself stores
/// no timer, matching how Cron/Profiles keep their refresh loops in the view.
@MainActor
@Observable
final class KanbanHarness {
    var board: KanbanBoard?
    var boards: [KanbanBoardSummary] = []
    var selectedBoardSlug: String?
    var selectedTaskID: String?
    var taskDetail: KanbanTaskDetail?
    var draft: KanbanDraft?
    var includeArchived: Bool = false
    var isLoading: Bool = false
    var lastError: String?
    /// Informational notice returned alongside an otherwise-successful mutation
    /// (e.g. the server's `warning` on create/move/edit). Kept separate from
    /// `lastError` so the banner can render it as a `.warning` rather than a red
    /// failure — the action succeeded.
    var lastWarning: String?
    var pluginUnavailable: Bool = false

    /// Task ids with an in-flight optimistic move. A poll that lands mid-drag
    /// preserves the local placement of these cards so the board can't snap a
    /// dragged card back before its `PATCH` resolves.
    var pendingMoves: Set<String> = []

    private let client: DashboardClient

    init(client: DashboardClient) {
        self.client = client
    }

    var selectedCard: KanbanCard? {
        guard let id = selectedTaskID, let board else { return nil }
        return board.columns.lazy.flatMap(\.tasks).first { $0.id == id }
    }

    // Keyed off `selectedCard` (board-derived), not `selectedTaskID`, so the
    // secondary pane closes itself if the selected card leaves the visible
    // board — e.g. a poll picks up a foreign archive/delete, or the card moves
    // into a hidden column. `secondaryPane` only renders detail when
    // `selectedCard` is non-nil, so keying the gate off the id could otherwise
    // strand a blank, undismissable pane.
    var showsSecondary: Bool { draft != nil || selectedCard != nil }

    // MARK: - Loading

    /// Fetches the board (the plugin-availability gate) and then, best-effort,
    /// the board list. A 404 on the board flips ``pluginUnavailable`` rather
    /// than surfacing a raw HTTP error.
    ///
    /// `isPoll` distinguishes the 4s background poll from a user-initiated
    /// refresh or a mutation's reconcile. The poll updates data *silently*: it
    /// never clears `lastError`/`lastWarning` (so a failed create, a 409
    /// move-rejection reason, or a server warning isn't wiped out from under the
    /// user a few seconds later) and never raises its own transient errors
    /// (a blip just leaves the last good board in place). Banners are owned by
    /// mutations and the manual Refresh button, which pass `isPoll == false`.
    func refresh(isPoll: Bool = false) async {
        // Only user-initiated refreshes flip `isLoading` — otherwise the 4s poll
        // would toggle it true→false every tick, flickering the Refresh button's
        // disabled state and the "No tasks" empty-state overlay on an idle board.
        if !isPoll { isLoading = true }
        defer { if !isPoll { isLoading = false } }
        do {
            let fetched = try await client.kanbanBoard(
                board: selectedBoardSlug,
                includeArchived: includeArchived
            )
            board = mergePreservingPendingMoves(fetched: fetched)
            pluginUnavailable = false
            if !isPoll {
                lastError = nil
                lastWarning = nil
            }
        } catch let DashboardClientError.http(statusCode, _) where statusCode == 404 {
            pluginUnavailable = true
            board = nil
            return
        } catch {
            if !isPoll {
                lastError = error.localizedDescription
            }
            return
        }
        // Board list is supplementary — a failure here shouldn't blank the board.
        // Note `includeArchived` is deliberately *not* forwarded here: that
        // toggle ("Show archived tasks") filters the archived task column, not
        // the board switcher. Forwarding it would also pull archived *boards*
        // into the menu / manage sheet, which is a separate concept.
        do {
            let response = try await client.kanbanBoards(includeArchived: false)
            boards = response.boards
            if selectedBoardSlug == nil {
                selectedBoardSlug = response.current
            }
        } catch {
            // Leave the previously-loaded board list in place.
        }
    }

    /// Reloads the detail payload for the selected task (comments/links/runs).
    /// The assignment is guarded on `selectedTaskID` still matching `id`: two
    /// quick selections can have their `/tasks/{id}` responses arrive out of
    /// order, and without the guard the slower (earlier) request could overwrite
    /// `taskDetail` with the wrong card's data and persist (poll never reloads
    /// detail).
    func loadDetail(id: String) async {
        do {
            let detail = try await client.kanbanTask(id: id)
            guard selectedTaskID == id else { return }
            taskDetail = detail
        } catch {
            guard selectedTaskID == id else { return }
            lastError = error.localizedDescription
        }
    }

    /// Fetches the worker log tail for a task. Errors are folded into the
    /// returned string so the detail pane can show them inline rather than
    /// flipping the surface banner.
    func taskLog(id: String, tail: Int = 200) async -> String {
        do {
            return try await client.kanbanTaskLog(id: id, tail: tail)
        } catch {
            return "Failed to load log: \(error.localizedDescription)"
        }
    }

    func selectTask(_ id: String) {
        draft = nil
        selectedTaskID = id
        taskDetail = nil
        Task { await loadDetail(id: id) }
    }

    func clearSelection() {
        selectedTaskID = nil
        taskDetail = nil
    }

    // MARK: - Drag move

    /// Optimistically moves a card to `to`, then issues the status `PATCH`. On
    /// success the authoritative placement is reconciled by a refresh (status
    /// routing may land the card elsewhere, e.g. `done`); on failure the
    /// pre-move snapshot is restored and a friendly error surfaced (a 409 maps
    /// to the server's reason — e.g. unfinished parents).
    func moveCard(id: String, from: String, to: String) async {
        guard from != to, let snapshot = board else { return }
        board = boardByMoving(snapshot, id: id, from: from, to: to)
        pendingMoves.insert(id)
        do {
            let response = try await client.kanbanUpdateTask(id: id, status: to)
            pendingMoves.remove(id)
            await refresh()
            // If the moved card is the one open in the detail pane, reload its
            // detail so `taskDetail.task.status` reflects where the server
            // actually routed it (status routing may differ from `to`), keeping
            // the pane's Status picker in sync.
            if selectedTaskID == id { await loadDetail(id: id) }
            // Surface the warning *after* refresh — refresh() clears it on
            // success, so setting it beforehand would wipe it. It rides its own
            // `.warning` channel (the move succeeded), separate from `lastError`.
            lastWarning = response.warning
        } catch let DashboardClientError.http(statusCode, body) where statusCode == 409 {
            board = snapshot
            pendingMoves.remove(id)
            lastError = friendlyMoveError(body)
        } catch {
            board = snapshot
            pendingMoves.remove(id)
            lastError = error.localizedDescription
        }
    }

    // MARK: - Task mutations

    func beginCreate() {
        clearSelection()
        draft = KanbanDraft(assignee: "")
    }

    func cancelCreate() { draft = nil }

    func createTask(_ draft: KanbanDraft) async {
        do {
            let response = try await client.kanbanCreateTask(
                title: draft.title,
                body: draft.body.isEmpty ? nil : draft.body,
                assignee: draft.assignee.isEmpty ? nil : draft.assignee,
                tenant: draft.tenant.isEmpty ? nil : draft.tenant,
                priority: draft.priority,
                workspaceKind: draft.workspaceKind,
                triage: draft.triage
            )
            self.draft = nil
            await refresh()
            lastWarning = response.warning
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateTask(
        id: String,
        title: String? = nil,
        body: String? = nil,
        assignee: String? = nil,
        priority: Int? = nil,
        status: String? = nil
    ) async {
        do {
            let response = try await client.kanbanUpdateTask(
                id: id,
                status: status,
                assignee: assignee,
                priority: priority,
                title: title,
                body: body
            )
            await loadDetail(id: id)
            await refresh()
            lastWarning = response.warning
        } catch let DashboardClientError.http(statusCode, body) where statusCode == 409 {
            lastError = friendlyMoveError(body)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteTask(id: String) async {
        do {
            try await client.kanbanDeleteTask(id: id)
            if selectedTaskID == id { clearSelection() }
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Comments & links

    /// Returns `true` on success so the caller can clear its input field only
    /// after the post lands — keeping the typed text on failure (a blip) instead
    /// of discarding it, matching the create flow.
    @discardableResult
    func addComment(taskId: String, body: String) async -> Bool {
        do {
            try await client.kanbanAddComment(taskId: taskId, body: body)
            await loadDetail(id: taskId)
            // Match the other mutations: refresh clears any stale error banner
            // and updates the board card's comment-count chip immediately rather
            // than waiting for the next poll.
            await refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func linkParent(parentId: String, to childId: String) async -> Bool {
        do {
            try await client.kanbanLink(parentId: parentId, childId: childId)
            await loadDetail(id: childId)
            await refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func linkChild(childId: String, of parentId: String) async -> Bool {
        do {
            try await client.kanbanLink(parentId: parentId, childId: childId)
            await loadDetail(id: parentId)
            await refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Removes the `parentId → childId` edge, then reloads the detail of
    /// `anchorId` (whichever task's pane is open).
    func unlink(parentId: String, childId: String, anchorId: String) async {
        do {
            try await client.kanbanUnlink(parentId: parentId, childId: childId)
            await loadDetail(id: anchorId)
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Board management

    func switchBoard(slug: String) async {
        do {
            try await client.kanbanSwitchBoard(slug: slug)
            clearSelection()
            if selectedBoardSlug == slug {
                // Same slug → `pollKey` is unchanged, so the poll task won't
                // restart; load explicitly.
                await refresh()
            } else {
                // Changing the slug restarts KanbanView's `pollKey`-keyed task,
                // whose loud first tick loads the new board — an explicit
                // refresh here would just double-fetch.
                selectedBoardSlug = slug
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func createBoard(slug: String, name: String?, switchTo: Bool) async {
        do {
            try await client.kanbanCreateBoard(slug: slug, name: name, switchTo: switchTo)
            if switchTo { selectedBoardSlug = slug }
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func renameBoard(slug: String, name: String) async {
        do {
            try await client.kanbanUpdateBoard(slug: slug, name: name)
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteBoard(slug: String) async {
        do {
            try await client.kanbanDeleteBoard(slug: slug)
            if selectedBoardSlug == slug { selectedBoardSlug = nil }
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Board transforms

    /// Rebuilds the board with `id` removed from the `from` column and appended
    /// to `to` (with its `status` updated so the card's own label stays in sync
    /// with the column it now sits in).
    private func boardByMoving(_ board: KanbanBoard, id: String, from: String, to: String) -> KanbanBoard {
        guard let moved = board.columns.first(where: { $0.name == from })?.tasks.first(where: { $0.id == id }) else {
            return board
        }
        let relocated = moved.withStatus(to)
        let columns = board.columns.map { column -> KanbanColumn in
            if column.name == from {
                return KanbanColumn(name: column.name, tasks: column.tasks.filter { $0.id != id })
            }
            if column.name == to {
                return KanbanColumn(name: column.name, tasks: column.tasks + [relocated])
            }
            return column
        }
        return KanbanBoard(
            columns: columns,
            tenants: board.tenants,
            assignees: board.assignees,
            latestEventId: board.latestEventId,
            now: board.now
        )
    }

    /// Merges a freshly-fetched board with the current one, keeping the local
    /// column placement of any card whose move is still in flight.
    private func mergePreservingPendingMoves(fetched: KanbanBoard) -> KanbanBoard {
        guard !pendingMoves.isEmpty, let current = board else { return fetched }
        var result = fetched
        for id in pendingMoves {
            guard let localColumn = current.columns.first(where: { col in col.tasks.contains { $0.id == id } })?.name,
                  let card = current.columns.lazy.flatMap(\.tasks).first(where: { $0.id == id })
            else { continue }
            // Strip the card from wherever the server placed it, then re-insert
            // it into the column it currently occupies locally.
            let columns = result.columns.map { column -> KanbanColumn in
                var tasks = column.tasks.filter { $0.id != id }
                if column.name == localColumn { tasks.append(card) }
                return KanbanColumn(name: column.name, tasks: tasks)
            }
            result = KanbanBoard(
                columns: columns,
                tenants: result.tenants,
                assignees: result.assignees,
                latestEventId: result.latestEventId,
                now: result.now
            )
        }
        return result
    }

    /// Turns a 409 body (`{"detail":"…"}` or raw text) into a one-line message.
    private func friendlyMoveError(_ body: String) -> String {
        let detail = decodedDetail(body) ?? body.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty {
            return "That move isn't allowed right now."
        }
        return detail
    }

    private func decodedDetail(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] as? String
        else { return nil }
        return detail
    }
}

extension KanbanCard {
    /// Returns a copy with a new `status`, used by the optimistic drag so the
    /// relocated card's own label matches the column it was dropped into.
    func withStatus(_ newStatus: String) -> KanbanCard {
        KanbanCard(
            id: id,
            title: title,
            body: body,
            status: newStatus,
            assignee: assignee,
            priority: priority,
            createdBy: createdBy,
            createdAt: createdAt,
            startedAt: startedAt,
            completedAt: completedAt,
            workspaceKind: workspaceKind,
            tenant: tenant,
            latestSummary: latestSummary,
            skills: skills,
            sessionId: sessionId,
            age: age,
            linkCounts: linkCounts,
            commentCount: commentCount,
            progress: progress,
            diagnostics: diagnostics,
            warnings: warnings
        )
    }
}

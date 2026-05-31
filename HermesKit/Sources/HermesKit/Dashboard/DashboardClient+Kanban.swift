import Foundation

// Client methods for the Hermes **Kanban** dashboard plugin. Split out of
// `DashboardClient.swift` because the surface is large (~18 routes + request
// bodies); it reuses the `internal` `get`/`sendDecoding`/`sendNoContent`
// helpers exactly like the inline Cron/Skills methods do.
//
// Every route is mounted under `/api/plugins/kanban` — the plugin prefix the
// dashboard applies via `app.include_router(router, prefix=…)`.
public extension DashboardClient {
    private static let kanbanBase = "/api/plugins/kanban"

    private func kanbanPath(_ suffix: String) -> String {
        Self.kanbanBase + suffix
    }

    // MARK: - Board

    /// Fetches the column layout for one board. `board == nil` returns the
    /// current board; `includeArchived` adds the `archived` column.
    func kanbanBoard(
        board: String? = nil,
        includeArchived: Bool = false,
        tenant: String? = nil
    ) async throws -> KanbanBoard {
        var items: [URLQueryItem] = []
        if let board { items.append(URLQueryItem(name: "board", value: board)) }
        if includeArchived { items.append(URLQueryItem(name: "include_archived", value: "true")) }
        if let tenant { items.append(URLQueryItem(name: "tenant", value: tenant)) }
        return try await get(path: kanbanPath("/board"), queryItems: items)
    }

    // MARK: - Tasks

    func kanbanTask(id: String) async throws -> KanbanTaskDetail {
        try await get(path: kanbanPath("/tasks/\(id)"))
    }

    func kanbanCreateTask(
        title: String,
        body: String? = nil,
        assignee: String? = nil,
        tenant: String? = nil,
        priority: Int = 0,
        workspaceKind: String = "scratch",
        parents: [String] = [],
        triage: Bool = false,
        skills: [String]? = nil
    ) async throws -> KanbanTaskResponse {
        let requestBody = CreateTaskBody(
            title: title,
            body: body,
            assignee: assignee,
            tenant: tenant,
            priority: priority,
            workspaceKind: workspaceKind,
            parents: parents,
            triage: triage,
            skills: skills
        )
        return try await sendDecoding(method: "POST", path: kanbanPath("/tasks"), body: requestBody)
    }

    /// Patches a task. Only the non-nil fields are sent (Swift's synthesized
    /// `Encodable` omits nil optionals via `encodeIfPresent`), so the
    /// status-only **move** call — `kanbanUpdateTask(id:status:)` — patches just
    /// the status. The server routes the status change itself and may land the
    /// card elsewhere (e.g. promoting into `done`); the returned card is
    /// authoritative.
    func kanbanUpdateTask(
        id: String,
        status: String? = nil,
        assignee: String? = nil,
        priority: Int? = nil,
        title: String? = nil,
        body: String? = nil,
        result: String? = nil,
        blockReason: String? = nil,
        summary: String? = nil
    ) async throws -> KanbanTaskResponse {
        let requestBody = UpdateTaskBody(
            status: status,
            assignee: assignee,
            priority: priority,
            title: title,
            body: body,
            result: result,
            blockReason: blockReason,
            summary: summary
        )
        return try await sendDecoding(method: "PATCH", path: kanbanPath("/tasks/\(id)"), body: requestBody)
    }

    @discardableResult
    func kanbanDeleteTask(id: String) async throws -> KanbanDeleteResponse {
        try await sendDecoding(method: "DELETE", path: kanbanPath("/tasks/\(id)"))
    }

    func kanbanBulk(
        ids: [String],
        status: String? = nil,
        assignee: String? = nil,
        priority: Int? = nil,
        archive: Bool? = nil
    ) async throws -> KanbanBulkResponse {
        let requestBody = BulkBody(
            ids: ids,
            status: status,
            assignee: assignee,
            priority: priority,
            archive: archive
        )
        return try await sendDecoding(method: "POST", path: kanbanPath("/tasks/bulk"), body: requestBody)
    }

    // MARK: - Comments & links

    @discardableResult
    func kanbanAddComment(taskId: String, body: String, author: String? = nil) async throws -> KanbanOKResponse {
        let requestBody = CommentBody(body: body, author: author)
        return try await sendDecoding(method: "POST", path: kanbanPath("/tasks/\(taskId)/comments"), body: requestBody)
    }

    @discardableResult
    func kanbanLink(parentId: String, childId: String) async throws -> KanbanOKResponse {
        let requestBody = LinkBody(parentId: parentId, childId: childId)
        return try await sendDecoding(method: "POST", path: kanbanPath("/links"), body: requestBody)
    }

    @discardableResult
    func kanbanUnlink(parentId: String, childId: String) async throws -> KanbanOKResponse {
        let items = [
            URLQueryItem(name: "parent_id", value: parentId),
            URLQueryItem(name: "child_id", value: childId),
        ]
        return try await sendDecoding(method: "DELETE", path: kanbanPath("/links"), queryItems: items)
    }

    // MARK: - Boards

    func kanbanBoards(includeArchived: Bool = false) async throws -> KanbanBoardsResponse {
        var items: [URLQueryItem] = []
        if includeArchived { items.append(URLQueryItem(name: "include_archived", value: "true")) }
        return try await get(path: kanbanPath("/boards"), queryItems: items)
    }

    /// Creates a board. Pass `switchTo: true` to also make it current. The
    /// harness reloads the board list afterwards, so no response is decoded.
    func kanbanCreateBoard(
        slug: String,
        name: String? = nil,
        description: String? = nil,
        icon: String? = nil,
        color: String? = nil,
        switchTo: Bool = false
    ) async throws {
        let requestBody = CreateBoardBody(
            slug: slug,
            name: name,
            description: description,
            icon: icon,
            color: color,
            switchTo: switchTo
        )
        try await sendNoContent(method: "POST", path: kanbanPath("/boards"), body: requestBody)
    }

    func kanbanUpdateBoard(
        slug: String,
        name: String? = nil,
        description: String? = nil,
        icon: String? = nil,
        color: String? = nil
    ) async throws {
        let requestBody = UpdateBoardBody(
            name: name,
            description: description,
            icon: icon,
            color: color
        )
        try await sendNoContent(method: "PATCH", path: kanbanPath("/boards/\(slug)"), body: requestBody)
    }

    func kanbanDeleteBoard(slug: String) async throws {
        try await sendNoContent(method: "DELETE", path: kanbanPath("/boards/\(slug)"))
    }

    func kanbanSwitchBoard(slug: String) async throws {
        try await sendNoContent(method: "POST", path: kanbanPath("/boards/\(slug)/switch"))
    }

    // MARK: - Read-only aux

    /// `GET /diagnostics` — board-wide diagnostics, optionally filtered by
    /// severity. The server wraps the list under `diagnostics`.
    func kanbanDiagnostics(severity: String? = nil) async throws -> [KanbanDiagnostic] {
        var items: [URLQueryItem] = []
        if let severity { items.append(URLQueryItem(name: "severity", value: severity)) }
        let response: DiagnosticsResponse = try await get(path: kanbanPath("/diagnostics"), queryItems: items)
        return response.diagnostics
    }

    /// `GET /runs/{id}` — full record for one worker run. Shape is unverified
    /// upstream, so it's returned as a raw `JSONValue` and rendered loosely.
    func kanbanRun(runId: Int) async throws -> JSONValue {
        try await get(path: kanbanPath("/runs/\(runId)"))
    }

    /// `GET /stats` — board-wide aggregate counters. Returned raw and rendered
    /// loosely (unverified shape).
    func kanbanStats() async throws -> JSONValue {
        try await get(path: kanbanPath("/stats"))
    }

    /// `GET /assignees` — the assignee pick-list. The board fetch already
    /// carries `assignees`; this is the standalone refresh.
    func kanbanAssignees() async throws -> [String] {
        let response: AssigneesResponse = try await get(path: kanbanPath("/assignees"))
        return response.assignees
    }

    /// `GET /tasks/{id}/log?tail=` — the task's worker log tail, returned as a
    /// single string (the response may carry either `lines` or `log`).
    func kanbanTaskLog(id: String, tail: Int? = nil) async throws -> String {
        var items: [URLQueryItem] = []
        if let tail { items.append(URLQueryItem(name: "tail", value: String(tail))) }
        let response: LogResponse = try await get(path: kanbanPath("/tasks/\(id)/log"), queryItems: items)
        return response.text
    }
}

// MARK: - Request bodies & aux response wrappers

private struct CreateTaskBody: Encodable {
    let title: String
    let body: String?
    let assignee: String?
    let tenant: String?
    let priority: Int
    let workspaceKind: String
    let parents: [String]
    let triage: Bool
    let skills: [String]?

    enum CodingKeys: String, CodingKey {
        case title, body, assignee, tenant, priority, parents, triage, skills
        case workspaceKind = "workspace_kind"
    }
}

private struct UpdateTaskBody: Encodable {
    let status: String?
    let assignee: String?
    let priority: Int?
    let title: String?
    let body: String?
    let result: String?
    let blockReason: String?
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case status, assignee, priority, title, body, result, summary
        case blockReason = "block_reason"
    }
}

private struct BulkBody: Encodable {
    let ids: [String]
    let status: String?
    let assignee: String?
    let priority: Int?
    let archive: Bool?
}

private struct CommentBody: Encodable {
    let body: String
    let author: String?
}

private struct LinkBody: Encodable {
    let parentId: String
    let childId: String

    enum CodingKeys: String, CodingKey {
        case parentId = "parent_id"
        case childId = "child_id"
    }
}

private struct CreateBoardBody: Encodable {
    let slug: String
    let name: String?
    let description: String?
    let icon: String?
    let color: String?
    let switchTo: Bool

    enum CodingKeys: String, CodingKey {
        case slug, name, description, icon, color
        case switchTo = "switch"
    }
}

private struct UpdateBoardBody: Encodable {
    let name: String?
    let description: String?
    let icon: String?
    let color: String?
}

private struct DiagnosticsResponse: Decodable {
    let diagnostics: [KanbanDiagnostic]
}

private struct AssigneesResponse: Decodable {
    let assignees: [String]
}

/// The task-log route's body isn't pinned upstream — accept either a `lines`
/// array or a single `log`/`text` string and normalize to one string.
private struct LogResponse: Decodable {
    let lines: [String]?
    let log: String?
    let body: String?

    /// Normalized log text, preferring an explicit string over joined lines.
    var text: String { body ?? log ?? lines?.joined(separator: "\n") ?? "" }

    enum CodingKeys: String, CodingKey {
        case lines, log
        case body = "text"
    }
}

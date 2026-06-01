import Foundation

// Codable models for the Hermes **Kanban** dashboard plugin, mounted at
// `/api/plugins/kanban/*`. The shapes mirror the plugin's `_task_dict` /
// `/board` / `/tasks/{id}` handlers (see the plan's "Confirmed API facts").
//
// Every timestamp decodes as `Double?` — Hermes emits epoch *integers*, which
// decode cleanly into `Double`, and keeping one numeric type avoids a second
// Int/Double split at every age/created/started field. Snake_case keys are
// mapped explicitly via `CodingKeys` (the client uses a vanilla `JSONDecoder`
// with no key strategy, matching the rest of `DashboardClient`).

// MARK: - Board

/// `GET /board` payload — the full column layout plus the board-wide pick lists
/// (`tenants`/`assignees`) the create/edit forms draw from.
public struct KanbanBoard: Codable, Equatable, Sendable {
    public let columns: [KanbanColumn]
    public let tenants: [String]
    public let assignees: [String]
    public let latestEventId: Int?
    public let now: Double?

    public init(
        columns: [KanbanColumn],
        tenants: [String] = [],
        assignees: [String] = [],
        latestEventId: Int? = nil,
        now: Double? = nil
    ) {
        self.columns = columns
        self.tenants = tenants
        self.assignees = assignees
        self.latestEventId = latestEventId
        self.now = now
    }

    enum CodingKeys: String, CodingKey {
        case columns, tenants, assignees, now
        case latestEventId = "latest_event_id"
    }
}

/// One lifecycle column (`triage`, `todo`, … `done`, `archived`). Identified by
/// its name — column names are unique within a board.
public struct KanbanColumn: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let tasks: [KanbanCard]

    public var id: String { name }

    public init(name: String, tasks: [KanbanCard]) {
        self.name = name
        self.tasks = tasks
    }
}

/// A task as it appears on the board or in a detail fetch. The board variant
/// carries the derived `linkCounts`/`commentCount`/`progress`/`diagnostics`/
/// `warnings` fields; the detail variant omits them (all optional, so one model
/// covers both).
public struct KanbanCard: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let body: String?
    public let status: String
    public let assignee: String?
    public let priority: Int?
    public let createdBy: String?
    public let createdAt: Double?
    public let startedAt: Double?
    public let completedAt: Double?
    public let workspaceKind: String?
    public let tenant: String?
    public let latestSummary: String?
    public let skills: [String]?
    public let sessionId: String?
    public let age: KanbanAge?
    public let linkCounts: KanbanLinkCounts?
    public let commentCount: Int?
    public let progress: KanbanProgress?
    public let diagnostics: [KanbanDiagnostic]?
    public let warnings: KanbanWarnings?

    public init(
        id: String,
        title: String,
        body: String? = nil,
        status: String,
        assignee: String? = nil,
        priority: Int? = nil,
        createdBy: String? = nil,
        createdAt: Double? = nil,
        startedAt: Double? = nil,
        completedAt: Double? = nil,
        workspaceKind: String? = nil,
        tenant: String? = nil,
        latestSummary: String? = nil,
        skills: [String]? = nil,
        sessionId: String? = nil,
        age: KanbanAge? = nil,
        linkCounts: KanbanLinkCounts? = nil,
        commentCount: Int? = nil,
        progress: KanbanProgress? = nil,
        diagnostics: [KanbanDiagnostic]? = nil,
        warnings: KanbanWarnings? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.status = status
        self.assignee = assignee
        self.priority = priority
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.workspaceKind = workspaceKind
        self.tenant = tenant
        self.latestSummary = latestSummary
        self.skills = skills
        self.sessionId = sessionId
        self.age = age
        self.linkCounts = linkCounts
        self.commentCount = commentCount
        self.progress = progress
        self.diagnostics = diagnostics
        self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey {
        case id, title, body, status, assignee, priority, tenant, skills, age, progress, diagnostics, warnings
        case createdBy = "created_by"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case workspaceKind = "workspace_kind"
        case latestSummary = "latest_summary"
        case sessionId = "session_id"
        case linkCounts = "link_counts"
        case commentCount = "comment_count"
    }
}

/// Relative-age block attached to every card (`age` key).
public struct KanbanAge: Codable, Equatable, Sendable {
    public let createdAgeSeconds: Double?
    public let startedAgeSeconds: Double?
    public let timeToCompleteSeconds: Double?

    public init(
        createdAgeSeconds: Double? = nil,
        startedAgeSeconds: Double? = nil,
        timeToCompleteSeconds: Double? = nil
    ) {
        self.createdAgeSeconds = createdAgeSeconds
        self.startedAgeSeconds = startedAgeSeconds
        self.timeToCompleteSeconds = timeToCompleteSeconds
    }

    enum CodingKeys: String, CodingKey {
        case createdAgeSeconds = "created_age_seconds"
        case startedAgeSeconds = "started_age_seconds"
        case timeToCompleteSeconds = "time_to_complete_seconds"
    }
}

/// `link_counts` — number of parent/child dependency links on a board card.
public struct KanbanLinkCounts: Codable, Equatable, Sendable {
    public let parents: Int?
    public let children: Int?

    public init(parents: Int? = nil, children: Int? = nil) {
        self.parents = parents
        self.children = children
    }
}

/// `progress` — subtask completion (`done`/`total`) when the card has children.
public struct KanbanProgress: Codable, Equatable, Sendable {
    public let done: Int?
    public let total: Int?

    public init(done: Int? = nil, total: Int? = nil) {
        self.done = done
        self.total = total
    }
}

/// `warnings` — an aggregate object (NOT a string list), with a per-kind
/// breakdown and the highest severity seen.
public struct KanbanWarnings: Codable, Equatable, Sendable {
    public let count: Int?
    public let kinds: [String: Int]?
    public let latestAt: Double?
    public let highestSeverity: String?

    public init(
        count: Int? = nil,
        kinds: [String: Int]? = nil,
        latestAt: Double? = nil,
        highestSeverity: String? = nil
    ) {
        self.count = count
        self.kinds = kinds
        self.latestAt = latestAt
        self.highestSeverity = highestSeverity
    }

    enum CodingKeys: String, CodingKey {
        case count, kinds
        case latestAt = "latest_at"
        case highestSeverity = "highest_severity"
    }
}

/// One entry in a card's `diagnostics` array. The server sends no stable id, so
/// `Identifiable` conformance is synthesized at the call site (`kind` + index) —
/// never via `UUID()` in a computed property, which would churn on every render.
public struct KanbanDiagnostic: Codable, Equatable, Sendable {
    public let kind: String?
    public let severity: String?
    public let count: Int?
    public let lastSeenAt: Double?
    public let message: String?

    public init(
        kind: String? = nil,
        severity: String? = nil,
        count: Int? = nil,
        lastSeenAt: Double? = nil,
        message: String? = nil
    ) {
        self.kind = kind
        self.severity = severity
        self.count = count
        self.lastSeenAt = lastSeenAt
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case kind, severity, count, message
        case lastSeenAt = "last_seen_at"
    }
}

// MARK: - Task detail

/// `GET /tasks/{id}` payload — the card plus its comments, event log, dependency
/// links, and run history.
public struct KanbanTaskDetail: Codable, Equatable, Sendable {
    public let task: KanbanCard
    public let comments: [KanbanComment]
    public let events: [KanbanEvent]
    public let links: KanbanLinks
    public let runs: [KanbanRun]

    public init(
        task: KanbanCard,
        comments: [KanbanComment] = [],
        events: [KanbanEvent] = [],
        links: KanbanLinks = KanbanLinks(),
        runs: [KanbanRun] = []
    ) {
        self.task = task
        self.comments = comments
        self.events = events
        self.links = links
        self.runs = runs
    }
}

public struct KanbanComment: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let author: String?
    public let body: String
    public let createdAt: Double?

    public init(id: Int, author: String? = nil, body: String, createdAt: Double? = nil) {
        self.id = id
        self.author = author
        self.body = body
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, author, body
        case createdAt = "created_at"
    }
}

/// One row in a task's event log. Rendered loosely — only the fields the detail
/// pane shows are modeled; the raw `payload` is intentionally dropped.
public struct KanbanEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let kind: String?
    public let createdAt: Double?
    public let runId: Int?

    public init(id: Int, kind: String? = nil, createdAt: Double? = nil, runId: Int? = nil) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.runId = runId
    }

    enum CodingKeys: String, CodingKey {
        case id, kind
        case createdAt = "created_at"
        case runId = "run_id"
    }
}

/// `links` — parent/child dependency edges as arrays of task-id strings.
public struct KanbanLinks: Codable, Equatable, Sendable {
    public let parents: [String]
    public let children: [String]

    public init(parents: [String] = [], children: [String] = []) {
        self.parents = parents
        self.children = children
    }
}

public struct KanbanRun: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let profile: String?
    public let status: String?
    public let outcome: String?
    public let summary: String?
    public let startedAt: Double?
    public let endedAt: Double?
    public let error: String?

    public init(
        id: Int,
        profile: String? = nil,
        status: String? = nil,
        outcome: String? = nil,
        summary: String? = nil,
        startedAt: Double? = nil,
        endedAt: Double? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.profile = profile
        self.status = status
        self.outcome = outcome
        self.summary = summary
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case id, profile, status, outcome, summary, error
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }
}

// MARK: - Boards

/// `GET /boards` payload — the multi-board switcher list plus the current slug.
public struct KanbanBoardsResponse: Codable, Equatable, Sendable {
    public let boards: [KanbanBoardSummary]
    public let current: String?

    public init(boards: [KanbanBoardSummary], current: String? = nil) {
        self.boards = boards
        self.current = current
    }
}

public struct KanbanBoardSummary: Codable, Equatable, Sendable, Identifiable {
    public let slug: String
    public let name: String?
    public let description: String?
    public let icon: String?
    public let color: String?
    public let isCurrent: Bool?
    public let counts: [String: Int]?
    public let total: Int?

    public var id: String { slug }

    public init(
        slug: String,
        name: String? = nil,
        description: String? = nil,
        icon: String? = nil,
        color: String? = nil,
        isCurrent: Bool? = nil,
        counts: [String: Int]? = nil,
        total: Int? = nil
    ) {
        self.slug = slug
        self.name = name
        self.description = description
        self.icon = icon
        self.color = color
        self.isCurrent = isCurrent
        self.counts = counts
        self.total = total
    }

    enum CodingKeys: String, CodingKey {
        case slug, name, description, icon, color, counts, total
        case isCurrent = "is_current"
    }
}

// MARK: - Mutation response envelopes

/// `POST /tasks` / `PATCH /tasks/{id}` → `{task, warning?}`.
public struct KanbanTaskResponse: Codable, Equatable, Sendable {
    public let task: KanbanCard
    public let warning: String?

    public init(task: KanbanCard, warning: String? = nil) {
        self.task = task
        self.warning = warning
    }
}

/// `DELETE /tasks/{id}` → `{deleted, task_id}`.
public struct KanbanDeleteResponse: Codable, Equatable, Sendable {
    public let deleted: Bool
    public let taskId: String?

    public init(deleted: Bool, taskId: String? = nil) {
        self.deleted = deleted
        self.taskId = taskId
    }

    enum CodingKeys: String, CodingKey {
        case deleted
        case taskId = "task_id"
    }
}

/// `POST /tasks/bulk` → `{results:[{id, ok, error?}]}`.
public struct KanbanBulkResponse: Codable, Equatable, Sendable {
    public let results: [KanbanBulkResult]

    public init(results: [KanbanBulkResult]) {
        self.results = results
    }
}

public struct KanbanBulkResult: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let ok: Bool
    public let error: String?

    public init(id: String, ok: Bool, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.error = error
    }
}

/// Generic `{ok}` envelope (comments, links, unlink).
public struct KanbanOKResponse: Codable, Equatable, Sendable {
    public let ok: Bool

    public init(ok: Bool) {
        self.ok = ok
    }
}

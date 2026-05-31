import Foundation
import Testing
@testable import HermesKit

@Suite
struct DashboardClientKanbanTests {
    // MARK: - Decode

    @Test
    func boardDecodesFixture() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/plugins/kanban/board", body: try loadFixtureData("kanban-board.json"))
        ])
        let client = makeClient(http: http)

        let board = try await client.kanbanBoard()

        #expect(board.columns.map(\.name) == ["triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done"])
        #expect(board.assignees == ["yuxi", "hermes", "ci-bot"])
        #expect(board.tenants == ["default", "ops"])
        #expect(board.latestEventId == 4821)

        let triage = try #require(board.columns.first { $0.name == "triage" })
        let card = try #require(triage.tasks.first)
        #expect(card.id == "task-001")
        #expect(card.priority == 2)
        #expect(card.skills == ["debugging"])
        #expect(card.linkCounts?.children == 1)
        #expect(card.commentCount == 2)
        #expect(card.progress?.total == 1)
        #expect(card.warnings?.count == 1)
        #expect(card.warnings?.kinds?["stale"] == 1)
        #expect(card.warnings?.highestSeverity == "warning")

        let running = try #require(board.columns.first { $0.name == "running" })
        let runningCard = try #require(running.tasks.first)
        #expect(runningCard.diagnostics?.first?.kind == "timeout")
        #expect(runningCard.diagnostics?.first?.severity == "error")
    }

    @Test
    func taskDetailDecodesFixture() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/plugins/kanban/tasks/task-001", body: try loadFixtureData("kanban-task-detail.json"))
        ])
        let client = makeClient(http: http)

        let detail = try await client.kanbanTask(id: "task-001")

        #expect(detail.task.id == "task-001")
        #expect(detail.task.latestSummary == "Reproduced once locally.")
        #expect(detail.comments.count == 2)
        #expect(detail.comments.first?.author == "yuxi")
        #expect(detail.events.contains { $0.kind == "run_started" && $0.runId == 5 })
        #expect(detail.links.parents == ["task-000"])
        #expect(detail.links.children == ["task-009"])
        let run = try #require(detail.runs.first)
        #expect(run.id == 5)
        #expect(run.outcome == "failure")
        #expect(run.error == "AssertionError: token expired")
    }

    @Test
    func boardsDecodesFixture() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/plugins/kanban/boards", body: try loadFixtureData("kanban-boards.json"))
        ])
        let client = makeClient(http: http)

        let response = try await client.kanbanBoards()

        #expect(response.current == "default")
        #expect(response.boards.count == 2)
        let def = try #require(response.boards.first { $0.slug == "default" })
        #expect(def.name == "Default")
        #expect(def.isCurrent == true)
        #expect(def.total == 4)
        #expect(def.counts?["triage"] == 1)
    }

    // MARK: - Request shapes

    @Test
    func createTaskPostsBody() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/plugins/kanban/tasks", body: try loadFixtureData("kanban-create-response.json"))
        ])
        let client = makeClient(http: http)

        let response = try await client.kanbanCreateTask(
            title: "Draft Q3 roadmap",
            body: "Outline the next quarter's priorities.",
            assignee: "yuxi",
            priority: 3,
            workspaceKind: "scratch",
            triage: true
        )
        #expect(response.task.id == "task-100")
        #expect(response.warning == "Parent task-050 is not yet done.")

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "POST")
        let json = try decodeBody(request)
        #expect(json["title"]?.stringValue == "Draft Q3 roadmap")
        #expect(json["assignee"]?.stringValue == "yuxi")
        #expect(json["priority"]?.intValue == 3)
        #expect(json["workspace_kind"]?.stringValue == "scratch")
        #expect(json["triage"]?.boolValue == true)
    }

    @Test
    func updateTaskMovePatchesStatusOnly() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/plugins/kanban/tasks/task-001", body: try loadFixtureData("kanban-create-response.json"))
        ])
        let client = makeClient(http: http)

        _ = try await client.kanbanUpdateTask(id: "task-001", status: "running")

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/api/plugins/kanban/tasks/task-001")
        let json = try decodeBody(request)
        #expect(json["status"]?.stringValue == "running")
        // Synthesized Encodable omits nil optionals — only `status` is sent.
        #expect(json["assignee"] == nil)
        #expect(json["title"] == nil)
        #expect(json["priority"] == nil)
    }

    @Test
    func deleteTaskIssuesDeleteToScopedPath() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/plugins/kanban/tasks/task-001", body: Data(#"{"deleted":true,"task_id":"task-001"}"#.utf8))
        ])
        let client = makeClient(http: http)

        let response = try await client.kanbanDeleteTask(id: "task-001")

        #expect(response.deleted == true)
        #expect(response.taskId == "task-001")
        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/plugins/kanban/tasks/task-001")
    }

    @Test
    func addCommentPostsBody() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/plugins/kanban/tasks/task-001/comments", body: Data(#"{"ok":true}"#.utf8))
        ])
        let client = makeClient(http: http)

        let response = try await client.kanbanAddComment(taskId: "task-001", body: "Looks good", author: "yuxi")

        #expect(response.ok == true)
        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/plugins/kanban/tasks/task-001/comments")
        let json = try decodeBody(request)
        #expect(json["body"]?.stringValue == "Looks good")
        #expect(json["author"]?.stringValue == "yuxi")
    }

    @Test
    func linkPostsParentAndChild() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/plugins/kanban/links", body: Data(#"{"ok":true}"#.utf8))
        ])
        let client = makeClient(http: http)

        _ = try await client.kanbanLink(parentId: "task-000", childId: "task-001")

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/plugins/kanban/links")
        let json = try decodeBody(request)
        #expect(json["parent_id"]?.stringValue == "task-000")
        #expect(json["child_id"]?.stringValue == "task-001")
    }

    @Test
    func unlinkDeletesWithQueryItems() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/plugins/kanban/links", body: Data(#"{"ok":true}"#.utf8))
        ])
        let client = makeClient(http: http)

        _ = try await client.kanbanUnlink(parentId: "task-000", childId: "task-001")

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/plugins/kanban/links")
        let query = request.url?.query ?? ""
        #expect(query.contains("parent_id=task-000"))
        #expect(query.contains("child_id=task-001"))
    }

    @Test
    func switchBoardPostsToSwitchSubpath() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/plugins/kanban/boards/ops/switch", body: Data())
        ])
        let client = makeClient(http: http)

        try await client.kanbanSwitchBoard(slug: "ops")

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/plugins/kanban/boards/ops/switch")
    }

    @Test
    func createBoardPostsBodyWithSwitchKey() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/plugins/kanban/boards", body: Data())
        ])
        let client = makeClient(http: http)

        try await client.kanbanCreateBoard(slug: "ops", name: "Ops", switchTo: true)

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "POST")
        let json = try decodeBody(request)
        #expect(json["slug"]?.stringValue == "ops")
        #expect(json["name"]?.stringValue == "Ops")
        #expect(json["switch"]?.boolValue == true)
    }

    // MARK: - Gating / error mapping

    @Test
    func boardFetchSurfaces404ForMissingPlugin() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/plugins/kanban/board", statusCode: 404, body: Data(#"{"detail":"Not Found"}"#.utf8))
        ])
        let client = makeClient(http: http)

        do {
            _ = try await client.kanbanBoard()
            Issue.record("expected a 404 to throw")
        } catch let DashboardClientError.http(statusCode, _) {
            #expect(statusCode == 404)
        }
    }

    @Test
    func moveSurfaces409WithServerBody() async throws {
        let body = Data(#"{"detail":"Cannot promote to ready: parent tasks are not done"}"#.utf8)
        let http = StubHTTP(responses: [
            .init(path: "/api/plugins/kanban/tasks/task-001", statusCode: 409, body: body)
        ])
        let client = makeClient(http: http)

        do {
            _ = try await client.kanbanUpdateTask(id: "task-001", status: "ready")
            Issue.record("expected a 409 to throw")
        } catch let DashboardClientError.http(statusCode, body) {
            #expect(statusCode == 409)
            #expect(body.contains("parent tasks are not done"))
        }
    }

    // MARK: - Helpers

    private func makeClient(http: StubHTTP) -> DashboardClient {
        DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok" },
            http: http
        )
    }

    private func decodeBody(_ request: URLRequest) throws -> [String: AnyJSON] {
        let body = try #require(request.httpBody ?? request.bodyStreamData())
        return try JSONDecoder().decode([String: AnyJSON].self, from: body)
    }

    private func loadFixtureData(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Dashboard")
        )
        return try Data(contentsOf: url)
    }
}

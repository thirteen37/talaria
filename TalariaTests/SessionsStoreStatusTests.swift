import Foundation
import HermesKit
import Testing
@testable import Talaria

/// Covers the session status state machine around the "awaiting input" state:
/// a permission request parks the session on `.awaitingInput` (distinct from
/// the `.working` agent-busy state), answering it resumes `.working`, and a
/// turn-ending cancel clears it back to `.idle`.
@MainActor
@Suite
struct SessionsStoreStatusTests {
    @Test
    func permissionRequestSetsAwaitingInput() async throws {
        let store = SessionsStore(
            manager: SessionManager(backendFactory: {
                PermissionEmittingBackend(sessionId: "acp-1")
            }),
            defaultCwd: "/tmp"
        )

        await store.openExisting(HermesSessionSummary(id: "acp-1", title: "ACP", source: "acp"))

        try await Self.waitUntil { store.statuses["acp-1"] == .awaitingInput }
        #expect(store.statuses["acp-1"] == .awaitingInput)
        await store.closeTab("acp-1")
    }

    @Test
    func streamEndingWhileAwaitingInputClearsStatus() async throws {
        // A backend that parks the session on a prompt and then disconnects
        // (stream ends) must not leave the sidebar / window badge stuck on
        // "needs you" — the stream-close cleanup clears `.awaitingInput` too.
        let store = SessionsStore(
            manager: SessionManager(backendFactory: {
                PermissionEmittingBackend(sessionId: "acp-1", finishAfterEmit: true)
            }),
            defaultCwd: "/tmp"
        )

        await store.openExisting(HermesSessionSummary(id: "acp-1", title: "ACP", source: "acp"))

        try await Self.waitUntil { store.statuses["acp-1"] == .idle }
        #expect(store.statuses["acp-1"] == .idle)
        await store.closeTab("acp-1")
    }

    @Test
    func markPermissionResolvedResumesWorking() {
        let store = Self.makeStore()
        store.statuses["s"] = .awaitingInput

        store.markPermissionResolved(id: "s")

        #expect(store.statuses["s"] == .working)
    }

    @Test
    func markPermissionResolvedIgnoresNonAwaitingStates() {
        let store = Self.makeStore()
        store.statuses["s"] = .working

        store.markPermissionResolved(id: "s")

        // Not awaiting → untouched (don't resurrect a finished turn into working).
        #expect(store.statuses["s"] == .working)
    }

    @Test
    func markTurnFinishedClearsAwaitingInput() {
        let store = Self.makeStore()
        store.statuses["s"] = .awaitingInput

        store.markTurnFinished(id: "s")

        // A reject/cancel ends the turn while it was parked on a prompt.
        #expect(store.statuses["s"] == .idle)
    }

    @Test
    func sessionsAwaitingInputListsOnlyBlockedSessionsInTabOrder() {
        let store = Self.makeStore()
        store.openSessions = [
            .init(id: "a", cwd: "/tmp"),
            .init(id: "b", cwd: "/tmp"),
            .init(id: "c", cwd: "/tmp")
        ]
        store.statuses["a"] = .awaitingInput
        store.statuses["b"] = .working
        store.statuses["c"] = .awaitingInput

        #expect(store.sessionsAwaitingInput == ["a", "c"])
    }

    private static func makeStore() -> SessionsStore {
        SessionsStore(
            manager: SessionManager(backendFactory: { MockChatBackend() }),
            defaultCwd: "/tmp"
        )
    }

    /// Polls `condition` on the main actor until it holds or the timeout
    /// elapses, yielding between checks so the store's notification task can run.
    private static func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                // Fail loudly rather than returning silently, so the helper is
                // safe for callers that don't follow it with their own assertion.
                Issue.record("waitUntil timed out before the condition held")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// A ``ChatBackend`` that emits a single permission request on `loadSession`,
/// mirroring how Hermes raises a blocking approval prompt mid-turn. The update
/// is buffered until the manager's pump subscribes (the replay path), so the
/// store's status observer still sees it.
private final class PermissionEmittingBackend: ChatBackend, @unchecked Sendable {
    nonisolated let notifications: AsyncThrowingStream<HermesNotification, Error>
    private let continuation: AsyncThrowingStream<HermesNotification, Error>.Continuation
    private let sessionId: SessionId
    /// When true, finish the notification stream right after emitting the prompt
    /// — simulating a backend disconnect while the session is parked awaiting
    /// input, which drives the store's stream-close cleanup.
    private let finishAfterEmit: Bool

    init(sessionId: SessionId, finishAfterEmit: Bool = false) {
        self.sessionId = sessionId
        self.finishAfterEmit = finishAfterEmit
        var captured: AsyncThrowingStream<HermesNotification, Error>.Continuation?
        self.notifications = AsyncThrowingStream { captured = $0 }
        self.continuation = captured!
    }

    func start(clientInfo: Implementation) async throws {}

    func newSession(cwd: String, mcpServers: [McpServer]) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: sessionId)
    }

    func loadSession(sessionId: SessionId, cwd: String, mcpServers: [McpServer]) async throws -> LoadSessionResponse {
        continuation.yield(.permissionRequest(PermissionRequestEvent(
            id: .number(1),
            request: RequestPermissionRequest(
                sessionId: self.sessionId,
                toolCall: ToolCallUpdate(toolCallId: "tool-1", title: "Run tests"),
                options: []
            ),
            kind: .permission,
            respond: { _ in }
        )))
        if finishAfterEmit {
            continuation.finish()
        }
        return LoadSessionResponse()
    }

    func prompt(sessionId: SessionId, content: [ContentBlock]) async throws -> PromptResponse {
        PromptResponse(stopReason: .endTurn)
    }

    func cancel(sessionId: SessionId) async throws {}
    func respond(id: JSONRPCID, error: JSONRPCError) async throws {}
    func close() async { continuation.finish() }
}

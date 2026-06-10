import Foundation
import Testing
@testable import HermesKit

@Suite
struct SessionManagerTests {
    @Test
    func openNewRegistersUnderBackendSessionId() async throws {
        let scripter = BackendScripter(newSessionId: "abc")
        let manager = SessionManager(backendFactory: { await scripter.next() })

        let state = try await manager.openNew(cwd: "/tmp/one")
        #expect(state.id == "abc")
        #expect(state.cwd == "/tmp/one")
    }

    @Test
    func openExistingRegistersUnderRequestedId() async throws {
        let scripter = BackendScripter()
        let manager = SessionManager(backendFactory: { await scripter.next() })

        let state = try await manager.openExisting(id: "session-1", cwd: "/tmp/proj")
        #expect(state.id == "session-1")
    }

    @Test
    func notificationsBufferedBeforeSubscriberAttachedAreReplayed() async throws {
        // Regression: when SessionsStore resumes a session, hermes streams the
        // historical transcript as session updates before the chat view model
        // subscribes. Without a replay buffer those would fan out to zero
        // subscribers and be dropped — the resumed session showed up empty.
        let scripter = BackendScripter()
        let manager = SessionManager(backendFactory: { await scripter.next() })

        let state = try await manager.openExisting(id: "sess", cwd: "/tmp")
        let backend = try await scripter.waitForBackend(at: 0)

        let first = SessionNotification(
            sessionId: state.id,
            update: .userMessageChunk(Content(content: .text("hi from past")))
        )
        let second = SessionNotification(
            sessionId: state.id,
            update: .agentMessageChunk(Content(content: .text("hello from past")))
        )
        backend.emit(.sessionUpdate(first))
        backend.emit(.sessionUpdate(second))
        // Let the pump deliver them to the (empty) subscriber set.
        try await Task.sleep(nanoseconds: 50_000_000)

        let stream = await manager.notifications(for: state.id)
        var iterator = stream.makeAsyncIterator()
        let receivedFirst = await iterator.next()
        let receivedSecond = await iterator.next()

        #expect(receivedFirst == .sessionUpdate(first))
        #expect(receivedSecond == .sessionUpdate(second))
    }

    @Test
    func notificationsFanOutToMultipleSubscribers() async throws {
        let scripter = BackendScripter(newSessionId: "sess")
        let manager = SessionManager(backendFactory: { await scripter.next() })

        let state = try await manager.openNew(cwd: "/tmp/x")
        let backend = try await scripter.waitForBackend(at: 0)

        let streamA = await manager.notifications(for: state.id)
        let streamB = await manager.notifications(for: state.id)
        try await Task.sleep(nanoseconds: 50_000_000)

        let notification = SessionNotification(
            sessionId: state.id,
            update: .agentMessageChunk(Content(content: .text("hello")))
        )
        backend.emit(.sessionUpdate(notification))

        var iterA = streamA.makeAsyncIterator()
        var iterB = streamB.makeAsyncIterator()
        let receivedA = await iterA.next()
        let receivedB = await iterB.next()

        #expect(receivedA == .sessionUpdate(notification))
        #expect(receivedB == .sessionUpdate(notification))
    }

    @Test
    func concurrentOpenExistingForSameIdResolvesToOneRegistration() async throws {
        let scripter = BackendScripter()
        let manager = SessionManager(backendFactory: { await scripter.next() })

        // Two parallel openExisting calls for the same id. Both boot fresh
        // backends; only one may register. Without the post-await re-check inside
        // openExisting, the second would overwrite the first and leak its client.
        let firstTask = Task { try await manager.openExisting(id: "shared-id", cwd: "/tmp/a") }
        let secondTask = Task { try await manager.openExisting(id: "shared-id", cwd: "/tmp/b") }

        var successes = 0
        var duplicates = 0
        for task in [firstTask, secondTask] {
            do {
                _ = try await task.value
                successes += 1
            } catch SessionManagerError.duplicateSession {
                duplicates += 1
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
        #expect(successes == 1)
        #expect(duplicates == 1)

        let active = await manager.activeSessions()
        #expect(active.count == 1)
    }

    @Test
    func reopenAfterStreamEndsReplaysHistoryToNewSubscriber() async throws {
        // The iOS reconnect path: when the WebSocket dies, the backend's
        // notification stream finishes, SessionsStore calls `close`, then
        // re-resumes via `openExisting` over the fresh tunnel. The new
        // subscriber must see the *new* backend's buffered history (the prior
        // dead session is gone, not replayed).
        let scripter = BackendScripter()
        let manager = SessionManager(backendFactory: { await scripter.next() })

        _ = try await manager.openExisting(id: "sess", cwd: "/tmp")
        let first = try await scripter.waitForBackend(at: 0)
        // Simulate the socket dying, then SessionsStore tearing the dead session
        // down. After close the old client/subscribers are gone.
        first.emit(.sessionUpdate(SessionNotification(
            sessionId: "sess",
            update: .agentMessageChunk(Content(content: .text("pre-death")))
        )))
        await manager.close(id: "sess")
        #expect(await manager.client(for: "sess") == nil)

        // Re-resume over a fresh backend (the rebuilt tunnel).
        _ = try await manager.openExisting(id: "sess", cwd: "/tmp")
        let second = try await scripter.waitForBackend(at: 1)
        #expect(second !== first)
        let recovered = SessionNotification(
            sessionId: "sess",
            update: .agentMessageChunk(Content(content: .text("recovered history")))
        )
        second.emit(.sessionUpdate(recovered))
        // Let the pump buffer it into the fresh session's replay.
        try await Task.sleep(nanoseconds: 50_000_000)

        let stream = await manager.notifications(for: "sess")
        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received == .sessionUpdate(recovered))

        await manager.close(id: "sess")
    }

    @Test
    func closeFinishesSubscribersAndDropsClient() async throws {
        let scripter = BackendScripter(newSessionId: "sess")
        let manager = SessionManager(backendFactory: { await scripter.next() })

        let state = try await manager.openNew(cwd: "/tmp/x")
        let stream = await manager.notifications(for: state.id)
        try await Task.sleep(nanoseconds: 30_000_000)

        await manager.close(id: state.id)

        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received == nil)
        let client = await manager.client(for: state.id)
        #expect(client == nil)
    }
}

/// Vends ``ScriptedChatBackend`` instances and keeps references so tests can
/// drive each session's notification stream directly — the gateway/WS wire is
/// covered separately by `GatewayChatClientTests`.
private actor BackendScripter {
    private(set) var backends: [ScriptedChatBackend] = []
    private let newSessionId: SessionId

    init(newSessionId: SessionId = "sess") {
        self.newSessionId = newSessionId
    }

    func next() -> any ChatBackend {
        let backend = ScriptedChatBackend(newSessionId: newSessionId)
        backends.append(backend)
        return backend
    }

    func waitForBackend(at position: Int) async throws -> ScriptedChatBackend {
        for _ in 0..<200 {
            if backends.count > position {
                return backends[position]
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ScripterError.noBackend
    }

    enum ScripterError: Error { case noBackend }
}

/// Minimal in-memory ``ChatBackend`` whose notification stream the test feeds
/// directly via ``emit(_:)``.
private final class ScriptedChatBackend: ChatBackend, @unchecked Sendable {
    nonisolated let notifications: AsyncThrowingStream<HermesNotification, Error>
    private let continuation: AsyncThrowingStream<HermesNotification, Error>.Continuation
    private let newSessionId: SessionId

    init(newSessionId: SessionId) {
        self.newSessionId = newSessionId
        var captured: AsyncThrowingStream<HermesNotification, Error>.Continuation?
        self.notifications = AsyncThrowingStream { captured = $0 }
        self.continuation = captured!
    }

    func emit(_ notification: HermesNotification) {
        continuation.yield(notification)
    }

    func start(clientInfo: Implementation) async throws {}

    func newSession(cwd: String, mcpServers: [McpServer]) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: newSessionId)
    }

    func loadSession(sessionId: SessionId, cwd: String, mcpServers: [McpServer]) async throws -> LoadSessionResponse {
        LoadSessionResponse()
    }

    func prompt(sessionId: SessionId, content: [ContentBlock]) async throws -> PromptResponse {
        PromptResponse(stopReason: .endTurn)
    }

    func cancel(sessionId: SessionId) async throws {}
    func respond(id: JSONRPCID, error: JSONRPCError) async throws {}
    func close() async { continuation.finish() }
}

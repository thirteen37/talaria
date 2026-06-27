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
    func transientTurnSignalsAreNotReplayedToLateSubscribers() async throws {
        // turnStarted/turnEnded are transient control signals: they must reach a
        // *live* subscriber but never be buffered for replay. Replaying a stale
        // turnEnded to a late subscriber would fire a spurious "agent finished".
        let scripter = BackendScripter()
        let manager = SessionManager(backendFactory: { await scripter.next() })

        let state = try await manager.openExisting(id: "sess", cwd: "/tmp")
        let backend = try await scripter.waitForBackend(at: 0)

        let update = SessionNotification(
            sessionId: state.id,
            update: .agentMessageChunk(Content(content: .text("buffered history")))
        )
        backend.emit(.turnStarted(state.id))
        backend.emit(.sessionUpdate(update))
        backend.emit(.turnEnded(state.id, clean: true))
        // Let the pump buffer them (no subscriber attached yet).
        try await Task.sleep(nanoseconds: 50_000_000)

        let stream = await manager.notifications(for: state.id)
        var iterator = stream.makeAsyncIterator()
        // Only the sessionUpdate replays; the transient turn signals are dropped,
        // so the first thing the late subscriber sees is the buffered update.
        let first = await iterator.next()
        #expect(first == .sessionUpdate(update))

        // A turn signal emitted *after* subscribing still reaches the subscriber.
        backend.emit(.turnEnded(state.id, clean: true))
        let second = await iterator.next()
        #expect(second == .turnEnded(state.id, clean: true))

        await manager.close(id: "sess")
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
    func deadSessionIdsFlagsAStreamThatEndedWithoutClose() async throws {
        // WS-death after a passing HTTP probe: the live-chat socket dies, so the
        // backend's notification stream finishes, but SessionsStore hasn't torn
        // the session down (close was never called). The session stays registered
        // and must surface as dead so the store can re-resume only it.
        let scripter = BackendScripter()
        let manager = SessionManager(backendFactory: { await scripter.next() })

        _ = try await manager.openExisting(id: "sess", cwd: "/tmp")
        let backend = try await scripter.waitForBackend(at: 0)
        #expect(await manager.deadSessionIds().isEmpty)

        // Finish the stream directly (the socket dying) — *not* via manager.close,
        // which would deregister the session entirely.
        await backend.close()
        try await pollUntil { await manager.deadSessionIds() == ["sess"] }
        #expect(await manager.deadSessionIds() == ["sess"])

        await manager.close(id: "sess")
    }

    @Test
    func closeDoesNotFlagSessionAsDead() async throws {
        // A normal close removes the session from the manager entirely, so it must
        // never surface as a dead session needing re-resume.
        let scripter = BackendScripter()
        let manager = SessionManager(backendFactory: { await scripter.next() })

        _ = try await manager.openExisting(id: "sess", cwd: "/tmp")
        _ = try await scripter.waitForBackend(at: 0)
        await manager.close(id: "sess")
        // Give any pump unwind a chance to run before asserting nothing flagged.
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(await manager.deadSessionIds().isEmpty)
    }

    @Test
    func reResumeAfterStreamEndClearsTheDeadFlag() async throws {
        // The re-resume path (close + openExisting over the fresh tunnel) registers
        // a healthy session under the same id; the new registration must not inherit
        // the previous one's dead flag.
        let scripter = BackendScripter()
        let manager = SessionManager(backendFactory: { await scripter.next() })

        _ = try await manager.openExisting(id: "sess", cwd: "/tmp")
        let first = try await scripter.waitForBackend(at: 0)
        await first.close()
        try await pollUntil { await manager.deadSessionIds() == ["sess"] }

        await manager.close(id: "sess")
        _ = try await manager.openExisting(id: "sess", cwd: "/tmp")
        _ = try await scripter.waitForBackend(at: 1)
        #expect(await manager.deadSessionIds().isEmpty)

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

/// Polls `condition` until it holds (or a bounded number of attempts elapse),
/// so a test can wait on the actor's pump observing an out-of-band stream end
/// without reaching into its private task.
private func pollUntil(
    attempts: Int = 200,
    _ condition: @Sendable () async -> Bool
) async throws {
    for _ in 0..<attempts {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
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

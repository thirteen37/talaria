import Foundation
import HermesKit
import Testing
@testable import Talaria

/// Covers the detached-send contract used by a popped-out chat window: a send
/// issued from the pop-out must use the pop-out's own view-local draft and clear
/// it, while leaving the source window's shared `prompt` untouched — the two
/// windows share one view model but have independent composer drafts.
@MainActor
@Suite
struct ChatDetachedSendTests {
    /// Keeps the (weakly-held) `SessionManager` alive for the test's duration.
    private let live = LiveManagers()

    private func makeIdleViewModel(
        id: SessionId,
        backend: PromptRecordingBackend
    ) async throws -> LocalChatViewModel {
        let manager = SessionManager(backendFactory: { backend })
        live.keep(manager)
        let session = try await manager.openExisting(id: id, cwd: "/tmp")
        return LocalChatViewModel(manager: manager, sessionId: session.id, cwd: "/tmp")
    }

    @Test
    func detachedSendUsesPassedTextAndLeavesSharedPromptUntouched() async throws {
        let backend = PromptRecordingBackend()
        let vm = try await makeIdleViewModel(id: "detached-send", backend: backend)

        // The source window's composer holds an in-progress draft.
        vm.prompt = "SHARED DRAFT"
        var detachedDraft = "hello from pop-out"

        await vm.sendPrompt(text: detachedDraft, clearComposer: { detachedDraft = "" })

        // The passed (detached) text drove the turn: it's echoed as the user
        // bubble and reaches the backend as the turn content.
        #expect(vm.messages.contains { $0.kind == .user && $0.text == "hello from pop-out" })
        #expect(vm.isSending)
        try await backend.waitForFirstPrompt()
        #expect(backend.sentTexts == ["hello from pop-out"])

        // The shared composer draft is left untouched (the source window keeps it).
        #expect(vm.prompt == "SHARED DRAFT")
        // The detached draft was cleared through the passed closure, not `prompt`.
        #expect(detachedDraft == "")
    }

    @Test
    func plainSendPromptStillClearsSharedComposer() async throws {
        // The non-detached entry point keeps its original behavior: it reads and
        // clears `self.prompt`.
        let backend = PromptRecordingBackend()
        let vm = try await makeIdleViewModel(id: "shared-send", backend: backend)

        vm.prompt = "type and send"
        await vm.sendPrompt()

        #expect(vm.prompt == "")
        #expect(vm.messages.contains { $0.kind == .user && $0.text == "type and send" })
    }
}

/// A ``ChatBackend`` recording the text of each `prompt` turn's content so a
/// test can assert what reached the wire. Mutable state is guarded by a serial
/// queue since `prompt` runs off the MainActor inside the view model's turn task.
private final class PromptRecordingBackend: ChatBackend, @unchecked Sendable {
    nonisolated let notifications: AsyncThrowingStream<HermesNotification, Error>
    private let continuation: AsyncThrowingStream<HermesNotification, Error>.Continuation
    private let queue = DispatchQueue(label: "PromptRecordingBackend")
    private var _sentTexts: [String] = []

    var sentTexts: [String] { queue.sync { _sentTexts } }

    init() {
        var captured: AsyncThrowingStream<HermesNotification, Error>.Continuation?
        self.notifications = AsyncThrowingStream { captured = $0 }
        self.continuation = captured!
    }

    func start(clientInfo: Implementation) async throws {}

    func newSession(cwd: String, mcpServers: [McpServer]) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: "prompt-recording-session")
    }

    func loadSession(sessionId: SessionId, cwd: String, mcpServers: [McpServer]) async throws -> LoadSessionResponse {
        LoadSessionResponse()
    }

    func prompt(sessionId: SessionId, content: [ContentBlock]) async throws -> PromptResponse {
        let text = content.compactMap { block -> String? in
            if case let .text(c) = block { return c.text }
            return nil
        }.joined()
        queue.sync { _sentTexts.append(text) }
        return PromptResponse(stopReason: .endTurn)
    }

    func cancel(sessionId: SessionId) async throws {}
    func respond(id: JSONRPCID, error: JSONRPCError) async throws {}
    func close() async { continuation.finish() }

    /// Polls until the first `prompt` turn lands (it runs in a detached task) or a
    /// short deadline elapses, so the assertion doesn't race the turn task.
    func waitForFirstPrompt() async throws {
        for _ in 0 ..< 100 {
            if !sentTexts.isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

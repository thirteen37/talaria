import Foundation
import HermesKit
import Testing
@testable import Talaria

/// Covers the send-while-busy path: a turn is in flight (`isSending == true`)
/// and the user dispatches a pending-input command, auto-queues plain text, or
/// types a non-pending slash. The live turn's busy state must survive untouched
/// and only the gateway's pending-input set (or auto-queued text) may dispatch.
@MainActor
@Suite
struct ChatBusySendTests {
    private func makeBusyViewModel(
        id: SessionId,
        backend: RecordingChatBackend
    ) async throws -> LocalChatViewModel {
        let manager = SessionManager(backendFactory: { backend })
        let session = try await manager.openExisting(id: id, cwd: "/tmp")
        let vm = LocalChatViewModel(manager: manager, sessionId: session.id, cwd: "/tmp")
        // Simulate a live turn the user is sending over.
        vm.isSending = true
        vm.turnStartDate = Self.liveTurnStart
        vm.statusText = Self.liveTurnStatus
        return vm
    }

    private static let liveTurnStart = Date(timeIntervalSince1970: 1_000)
    private static let liveTurnStatus = "Hermes is working in /tmp..."

    @Test
    func pendingInputSlashWhileBusyDispatchesWithoutClobberingTurn() async throws {
        let backend = RecordingChatBackend()
        let vm = try await makeBusyViewModel(id: "busy-queue", backend: backend)

        vm.prompt = "/queue revisit migration"
        await vm.sendPrompt()

        // The slash reached the backend with name + arg recombined.
        #expect(backend.slashCommands == ["queue revisit migration"])
        // The live turn's busy lifecycle is untouched.
        #expect(vm.isSending)
        #expect(vm.turnStartDate == Self.liveTurnStart)
        #expect(vm.statusText == Self.liveTurnStatus)
        // Composer cleared; feedback is an inline event line, never a user bubble.
        #expect(vm.prompt == "")
        #expect(vm.messages.contains { $0.kind == .event && $0.text.contains("Queued: revisit migration") })
        #expect(!vm.messages.contains { $0.kind == .user })
    }

    @Test
    func steerWhileBusyDispatchesWithSteeringMarker() async throws {
        let backend = RecordingChatBackend()
        let vm = try await makeBusyViewModel(id: "busy-steer", backend: backend)

        vm.prompt = "/steer use Swift, not Python"
        await vm.sendPrompt()

        #expect(backend.slashCommands == ["steer use Swift, not Python"])
        #expect(vm.isSending)
        #expect(vm.messages.contains { $0.kind == .event && $0.text.contains("Steering: use Swift, not Python") })
    }

    @Test
    func plainTextWhileBusyAutoQueuesWithTipFirstThenTerse() async throws {
        LocalChatViewModel.resetAutoQueueTip()
        let backend = RecordingChatBackend()
        let vm = try await makeBusyViewModel(id: "busy-auto", backend: backend)

        vm.prompt = "follow up question"
        await vm.sendPrompt()

        // Plain text is auto-wrapped as `/queue …`.
        #expect(backend.slashCommands == ["queue follow up question"])
        #expect(vm.isSending)
        #expect(vm.turnStartDate == Self.liveTurnStart)
        #expect(vm.prompt == "")
        // First auto-queue surfaces the one-time tip.
        #expect(vm.messages.contains { $0.kind == .event && $0.text.contains("Tip:") })

        // A second auto-queue gets the terse line, no tip.
        vm.prompt = "and another"
        await vm.sendPrompt()
        #expect(backend.slashCommands == ["queue follow up question", "queue and another"])
        let terse = vm.messages.filter { $0.kind == .event && $0.text == "Queued." }
        #expect(terse.count == 1)
    }

    @Test
    func nonPendingSlashWhileBusyIsNoOp() async throws {
        let backend = RecordingChatBackend()
        let vm = try await makeBusyViewModel(id: "busy-help", backend: backend)

        vm.prompt = "/help"
        await vm.sendPrompt()

        // Nothing dispatched; the composer text is left so the user can resend.
        #expect(backend.slashCommands.isEmpty)
        #expect(vm.prompt == "/help")
        #expect(vm.messages.isEmpty)
        #expect(vm.isSending)
        #expect(vm.statusText == Self.liveTurnStatus)
    }

    @Test
    func plainTextWhileIdleStartsRealTurnNotASlash() async throws {
        let backend = RecordingChatBackend()
        let manager = SessionManager(backendFactory: { backend })
        let session = try await manager.openExisting(id: "idle-send", cwd: "/tmp")
        let vm = LocalChatViewModel(manager: manager, sessionId: session.id, cwd: "/tmp")

        vm.prompt = "hello there"
        await vm.sendPrompt()

        // Idle plain text takes the normal turn path: no slash, the user bubble
        // is echoed, and the turn is marked busy (the prompt task owns it now).
        #expect(backend.slashCommands.isEmpty)
        #expect(vm.isSending)
        #expect(vm.prompt == "")
        #expect(vm.messages.contains { $0.kind == .user && $0.text == "hello there" })
    }
}

/// A ``ChatBackend`` that records the slash commands it receives so a test can
/// assert what `LocalChatViewModel` dispatched. `slash` resolves as an empty
/// `.output` (the shape Hermes returns for the pending-input set), so the view
/// model's busy path relies on its own marker for feedback.
private final class RecordingChatBackend: ChatBackend, @unchecked Sendable {
    nonisolated let notifications: AsyncThrowingStream<HermesNotification, Error>
    private let continuation: AsyncThrowingStream<HermesNotification, Error>.Continuation

    private(set) var slashCommands: [String] = []
    /// Outcome `slash` resolves with. Defaults to the empty `.output` Hermes
    /// returns for the pending-input set; tests can script a `.prefill` to
    /// exercise the `/undo`-while-busy guard.
    var slashOutcome: SlashOutcome = .output("")

    init() {
        var captured: AsyncThrowingStream<HermesNotification, Error>.Continuation?
        self.notifications = AsyncThrowingStream { captured = $0 }
        self.continuation = captured!
    }

    func start(clientInfo: Implementation) async throws {}

    func newSession(cwd: String, mcpServers: [McpServer]) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: "recording-session")
    }

    func loadSession(sessionId: SessionId, cwd: String, mcpServers: [McpServer]) async throws -> LoadSessionResponse {
        LoadSessionResponse()
    }

    func prompt(sessionId: SessionId, content: [ContentBlock]) async throws -> PromptResponse {
        PromptResponse(stopReason: .endTurn)
    }

    func cancel(sessionId: SessionId) async throws {}

    func slash(sessionId: SessionId, command: String) async throws -> SlashOutcome {
        slashCommands.append(command)
        return slashOutcome
    }

    func respond(id: JSONRPCID, error: JSONRPCError) async throws {}
    func close() async { continuation.finish() }
}

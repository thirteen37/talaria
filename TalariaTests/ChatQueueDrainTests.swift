import Foundation
import HermesKit
import Testing
@testable import Talaria

/// Covers the mid-turn queue → drain path (the reported bug): a message sent
/// while a turn is in flight is *held* (not dropped), then submitted as a real
/// LLM turn once the current turn ends cleanly. A cancel/error halts the drain.
///
/// Unlike ``ChatBusySendTests`` (which fakes `isSending` with no live turn),
/// these drive a *real* turn through ``GatedRecordingBackend`` so the queue
/// genuinely drains on clean completion.
@MainActor
@Suite
struct ChatQueueDrainTests {
    /// Keeps the (weakly-held) `SessionManager` alive for the test's duration.
    private let live = LiveManagers()

    private func makeViewModel(
        id: SessionId,
        backend: GatedRecordingBackend
    ) async throws -> LocalChatViewModel {
        let manager = SessionManager(backendFactory: { backend })
        live.keep(manager)
        let session = try await manager.openExisting(id: id, cwd: "/tmp")
        return LocalChatViewModel(manager: manager, sessionId: session.id, cwd: "/tmp")
    }

    /// Spins the run loop until `condition` holds or a bounded number of yields
    /// elapse, so the async hops between turn completion and the next drain land
    /// before assertions run. Fails the test rather than hanging if it never does.
    private func wait(
        for condition: @escaping () async -> Bool,
        _ message: Comment
    ) async {
        for _ in 0 ..< 200 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record(message)
    }

    @Test
    func plainTextQueuedMidTurnDrainsOnCleanCompletion() async throws {
        let backend = GatedRecordingBackend()
        let vm = try await makeViewModel(id: "drain-one", backend: backend)

        // Start a real turn.
        vm.prompt = "first"
        await vm.sendPrompt()
        await wait(for: { await backend.inFlightCount == 1 }, "first turn never reached the backend")
        #expect(vm.isSending)
        #expect(await backend.promptedContents == ["first"])

        // Queue a follow-up mid-turn — it must be held, not dropped, and must
        // NOT start a second turn while the first runs.
        vm.prompt = "follow up"
        await vm.sendPrompt()
        #expect(await backend.inFlightCount == 1) // still only the live turn
        #expect(vm.prompt == "")

        // The live turn ends cleanly → the queued message submits as a real turn.
        await backend.completeOldestTurn()
        await wait(for: { await backend.promptedContents == ["first", "follow up"] },
                   "queued message did not drain after clean completion")
        // It became a real user turn (echoed bubble).
        #expect(vm.messages.contains { $0.kind == .user && $0.text == "follow up" })

        await backend.completeOldestTurn() // let the drained turn finish
    }

    @Test
    func explicitQueueCommandDrainsFIFO() async throws {
        let backend = GatedRecordingBackend()
        let vm = try await makeViewModel(id: "drain-fifo", backend: backend)

        vm.prompt = "first"
        await vm.sendPrompt()
        await wait(for: { await backend.inFlightCount == 1 }, "first turn never started")

        // Two explicit /queue commands over the live turn.
        vm.prompt = "/queue alpha"
        await vm.sendPrompt()
        vm.prompt = "/queue beta"
        await vm.sendPrompt()
        // Both recorded as slash dispatches, neither started a turn.
        #expect(await backend.slashCommands == ["queue alpha", "queue beta"])
        #expect(await backend.inFlightCount == 1)

        // Each clean completion drains exactly one, in order.
        await backend.completeOldestTurn()
        await wait(for: { await backend.promptedContents == ["first", "alpha"] },
                   "first queued item did not drain")
        await backend.completeOldestTurn()
        await wait(for: { await backend.promptedContents == ["first", "alpha", "beta"] },
                   "second queued item did not drain FIFO")
        await backend.completeOldestTurn() // drain empty now
    }

    @Test
    func cancelHaltsTheDrain() async throws {
        let backend = GatedRecordingBackend()
        let vm = try await makeViewModel(id: "drain-cancel", backend: backend)

        vm.prompt = "first"
        await vm.sendPrompt()
        await wait(for: { await backend.inFlightCount == 1 }, "first turn never started")

        vm.prompt = "held"
        await vm.sendPrompt()

        // The turn ends via cancellation, not a clean stop → no drain.
        await backend.failOldestTurn(CancellationError())
        // Give any (erroneous) drain a chance to fire before asserting it didn't.
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(await backend.promptedContents == ["first"])
        #expect(!vm.isSending)
        // The queued item persists and resumes after the next clean turn.
        vm.prompt = "next"
        await vm.sendPrompt()
        await wait(for: { await backend.inFlightCount == 1 }, "resume turn never started")
        await backend.completeOldestTurn()
        await wait(for: { await backend.promptedContents.contains("held") },
                   "queued item did not resume after a later clean turn")
    }

    @Test
    func errorHaltsTheDrain() async throws {
        let backend = GatedRecordingBackend()
        let vm = try await makeViewModel(id: "drain-error", backend: backend)

        vm.prompt = "first"
        await vm.sendPrompt()
        await wait(for: { await backend.inFlightCount == 1 }, "first turn never started")

        vm.prompt = "held"
        await vm.sendPrompt()

        await backend.failOldestTurn(GatewayChatError.server("boom"))
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(await backend.promptedContents == ["first"])
        #expect(vm.hasError)
    }
}

/// A ``ChatBackend`` whose turns are *gated*: `prompt(...)` suspends until the
/// test releases it, so a test can hold a turn open, queue over it, and observe
/// the drain on completion. Records the slash commands and prompt texts it saw.
/// `/queue`/`/q` resolve as `.submit` (Hermes' shape), so the view model's
/// enqueue seam is exercised; other slashes resolve as an empty `.output`.
private actor GatedRecordingBackend: ChatBackend {
    nonisolated let notifications: AsyncThrowingStream<HermesNotification, Error>
    private let continuation: AsyncThrowingStream<HermesNotification, Error>.Continuation

    private(set) var slashCommands: [String] = []
    private(set) var promptedContents: [String] = []
    private var turnGates: [CheckedContinuation<PromptResponse, Error>] = []

    var inFlightCount: Int { turnGates.count }

    init() {
        var captured: AsyncThrowingStream<HermesNotification, Error>.Continuation?
        self.notifications = AsyncThrowingStream { captured = $0 }
        self.continuation = captured!
    }

    func start(clientInfo: Implementation) async throws {}

    func newSession(cwd: String, mcpServers: [McpServer]) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: "gated-session")
    }

    func loadSession(sessionId: SessionId, cwd: String, mcpServers: [McpServer]) async throws -> LoadSessionResponse {
        LoadSessionResponse()
    }

    func prompt(sessionId: SessionId, content: [ContentBlock]) async throws -> PromptResponse {
        promptedContents.append(content.compactMap { $0.plainText }.joined())
        return try await withCheckedThrowingContinuation { turnGates.append($0) }
    }

    func cancel(sessionId: SessionId) async throws {}

    func slash(sessionId: SessionId, command: String) async throws -> SlashOutcome {
        slashCommands.append(command)
        let parsed = SlashCommand(parsing: command)
        switch parsed.name.lowercased() {
        case "queue", "q":
            return .submit(message: parsed.arg, notice: nil)
        default:
            return .output("")
        }
    }

    func respond(id: JSONRPCID, error: JSONRPCError) async throws {}
    func close() async { continuation.finish() }

    /// Resolve the oldest in-flight turn as a clean end-of-turn.
    func completeOldestTurn() {
        guard !turnGates.isEmpty else { return }
        turnGates.removeFirst().resume(returning: PromptResponse(stopReason: .endTurn))
    }

    /// Resolve the oldest in-flight turn as a failure (cancellation/error).
    func failOldestTurn(_ error: Error) {
        guard !turnGates.isEmpty else { return }
        turnGates.removeFirst().resume(throwing: error)
    }
}

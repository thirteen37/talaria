import Foundation
import HermesKit
import Testing
@testable import Talaria

/// Covers the native chat commands wired in this change: `/bg` (background
/// prompts + live indicator state), `/branch`, and `/handoff`. Each drives
/// ``LocalChatViewModel`` against a scriptable backend and asserts the RPC it
/// dispatched, the transcript feedback, and that the live turn is never started
/// or clobbered.
@MainActor
@Suite
struct ChatNativeCommandsTests {
    /// `LocalChatViewModel` holds its `SessionManager` weakly, so a test must keep
    /// the manager alive itself — otherwise it can dealloc before `sendPrompt`
    /// reads it (a scheduling race under the parallel runner). One per test
    /// instance; Swift Testing makes a fresh suite instance per `@Test`.
    private let live = LiveManagers()

    private func makeViewModel(
        id: SessionId,
        backend: ScriptableChatBackend
    ) async throws -> LocalChatViewModel {
        let manager = SessionManager(backendFactory: { backend })
        live.keep(manager)
        let session = try await manager.openExisting(id: id, cwd: "/tmp")
        return LocalChatViewModel(manager: manager, sessionId: session.id, cwd: "/tmp")
    }

    private func wait(
        for condition: @escaping () -> Bool,
        _ message: Comment
    ) async {
        // Sleep (not just yield) between checks: the detached handoff poll suspends
        // on real `Task.sleep` intervals, so the condition needs wall-clock to pass.
        for _ in 0 ..< 400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record(message)
    }

    // MARK: - /bg

    @Test
    func backgroundCommandIdleDispatchesAndAddsRunningTask() async throws {
        let backend = ScriptableChatBackend()
        backend.backgroundTaskId = "bg_1"
        let vm = try await makeViewModel(id: "bg-idle", backend: backend)

        vm.prompt = "/bg summarise the diff"
        await vm.sendPrompt()

        #expect(backend.promptBackgroundTexts == ["summarise the diff"])
        #expect(backend.promptedContents.isEmpty)              // no foreground turn
        #expect(!vm.isSending)                                  // and not left busy
        #expect(vm.backgroundTasks.count == 1)
        #expect(vm.backgroundTasks.first?.state == .running)
        #expect(vm.messages.contains { $0.kind == .event && $0.text.contains("Background task started") })
    }

    @Test
    func backgroundCommandMidTurnDispatchesWithoutTouchingLiveTurn() async throws {
        let backend = ScriptableChatBackend()
        let vm = try await makeViewModel(id: "bg-busy", backend: backend)
        vm.isSending = true
        let turnStart = Date(timeIntervalSince1970: 1)
        vm.turnStartDate = turnStart

        vm.prompt = "/bg run the tests"
        await vm.sendPrompt()

        #expect(backend.promptBackgroundTexts == ["run the tests"])
        #expect(backend.promptedContents.isEmpty)
        // Live turn untouched: still busy, same start date, nothing queued.
        #expect(vm.isSending)
        #expect(vm.turnStartDate == turnStart)
        #expect(vm.backgroundTasks.first?.state == .running)
    }

    @Test
    func backgroundCompleteFlipsTaskAndRendersResult() async throws {
        let backend = ScriptableChatBackend()
        backend.backgroundTaskId = "bg_42"
        let vm = try await makeViewModel(id: "bg-done", backend: backend)
        await vm.start()

        vm.prompt = "/bg do the thing"
        await vm.sendPrompt()
        #expect(vm.backgroundTasks.first?.state == .running)

        backend.emit(.sessionUpdate(SessionNotification(
            sessionId: "bg-done",
            update: .backgroundComplete(taskId: "bg_42", text: "done: 7 files")
        )))

        await wait(for: { vm.backgroundTasks.first?.state == .finished },
                   "background task never flipped to finished")
        #expect(vm.messages.contains { $0.kind == .event && $0.text.contains("Background task finished") && $0.text.contains("done: 7 files") })
    }

    @Test
    func backgroundCompleteMidStreamDoesNotSplitForegroundReply() async throws {
        // `/bg` runs concurrently with the foreground turn, so `background.complete`
        // can arrive while the agent reply is mid-stream. It must not reset the
        // streaming cursor, or the next agent chunk would open a second bubble.
        let backend = ScriptableChatBackend()
        backend.backgroundTaskId = "bg_x"
        let vm = try await makeViewModel(id: "bg-midstream", backend: backend)
        await vm.start()

        backend.emit(.sessionUpdate(SessionNotification(
            sessionId: "bg-midstream", update: .agentMessageChunk(Content(content: .text("Hello "))))))
        await wait(for: { vm.messages.contains { $0.kind == .agent } }, "agent stream never started")

        backend.emit(.sessionUpdate(SessionNotification(
            sessionId: "bg-midstream", update: .backgroundComplete(taskId: "bg_x", text: "bg done"))))
        await wait(for: { vm.messages.contains { $0.text.contains("Background task finished") } },
                   "background completion never rendered")

        backend.emit(.sessionUpdate(SessionNotification(
            sessionId: "bg-midstream", update: .agentMessageChunk(Content(content: .text("world"))))))
        await wait(for: { vm.messages.first(where: { $0.kind == .agent })?.text == "Hello world" },
                   "second agent chunk did not merge into the in-progress reply")

        // Exactly one agent bubble, carrying the whole reply.
        let agentBubbles = vm.messages.filter { $0.kind == .agent }
        #expect(agentBubbles.count == 1)
        #expect(agentBubbles.first?.text == "Hello world")
    }

    // MARK: - /branch

    @Test
    func branchCommandCallsBranchSessionAndConfirms() async throws {
        let backend = ScriptableChatBackend()
        backend.branchResult = BranchResult(sessionId: "rt-2", title: "spike", parent: "old-key")
        let vm = try await makeViewModel(id: "branch-ok", backend: backend)

        vm.prompt = "/branch spike"
        await vm.sendPrompt()

        #expect(backend.branchNames == ["spike"])
        #expect(backend.promptedContents.isEmpty) // not an LLM turn
        #expect(vm.messages.contains { $0.kind == .event && $0.text.contains("Branched into") && $0.text.contains("spike") })
    }

    @Test
    func branchCommandSurfacesEmptyHistoryError() async throws {
        let backend = ScriptableChatBackend()
        backend.branchError = GatewayChatError.server("nothing to branch — send a message first")
        let vm = try await makeViewModel(id: "branch-empty", backend: backend)

        vm.prompt = "/fork"
        await vm.sendPrompt()

        #expect(backend.branchNames == [nil]) // no arg → nil name
        #expect(vm.messages.contains { $0.kind == .event && $0.text.contains("nothing to branch") })
    }

    // MARK: - /handoff

    @Test
    func handoffWithoutPlatformShowsUsage() async throws {
        let backend = ScriptableChatBackend()
        let vm = try await makeViewModel(id: "handoff-usage", backend: backend)

        vm.prompt = "/handoff"
        await vm.sendPrompt()

        #expect(backend.handoffRequests.isEmpty)
        #expect(vm.messages.contains { $0.kind == .event && $0.text.contains("Usage: /handoff") })
    }

    @Test
    func handoffDrivesRequestThenPollToCompletion() async throws {
        let backend = ScriptableChatBackend()
        backend.handoffRequestResult = HandoffRequestResult(queued: true, sessionKey: "k", platform: "slack", homeName: "#hermes")
        backend.handoffStates = [HandoffState(state: "completed", platform: "slack", error: "")]
        let vm = try await makeViewModel(id: "handoff-ok", backend: backend)
        vm.handoffPollInterval = .milliseconds(5)

        vm.prompt = "/handoff slack"
        await vm.sendPrompt()

        // The request + "Handing off" line are synchronous; the poll runs detached
        // (off the turn-busy state) so the terminal line arrives asynchronously.
        #expect(backend.handoffRequests == ["slack"])
        #expect(vm.messages.contains { $0.kind == .event && $0.text.contains("Handing off to #hermes") })
        #expect(!vm.isSending) // session stays idle while the handoff settles
        await wait(for: { vm.messages.contains { $0.kind == .event && $0.text.contains("Handed off to #hermes") } },
                   "handoff completion line never arrived")
    }

    @Test
    func handoffSurfacesNotConfiguredError() async throws {
        let backend = ScriptableChatBackend()
        backend.handoffRequestError = GatewayChatError.server("platform 'slack' is not configured/enabled in the gateway")
        let vm = try await makeViewModel(id: "handoff-unconfigured", backend: backend)

        vm.prompt = "/handoff slack"
        await vm.sendPrompt()

        #expect(vm.messages.contains { $0.kind == .event && $0.text.contains("not configured/enabled") })
    }

    @Test
    func handoffTimeoutCallsFailHandoff() async throws {
        let backend = ScriptableChatBackend()
        backend.handoffStates = [HandoffState(state: "pending", platform: "slack", error: "")]
        let vm = try await makeViewModel(id: "handoff-timeout", backend: backend)
        vm.handoffPollAttempts = 2
        vm.handoffPollInterval = .milliseconds(5)

        vm.prompt = "/handoff slack"
        await vm.sendPrompt()

        await wait(for: { backend.handoffFails == ["timed out waiting for handoff"] },
                   "timed-out handoff never called failHandoff")
        #expect(vm.messages.contains { $0.kind == .event && $0.text.contains("timed out") })
    }

    @Test
    func messageSentDuringHandoffPollIsNotStranded() async throws {
        // The handoff poll must not hold the turn-busy state: otherwise a message
        // typed while it runs would be queued and stranded (the queue only drains
        // on a clean LLM turn, which a handoff never runs).
        let backend = ScriptableChatBackend()
        backend.handoffStates = [HandoffState(state: "pending", platform: "slack", error: "")]
        let vm = try await makeViewModel(id: "handoff-nostrand", backend: backend)
        vm.handoffPollAttempts = 100
        vm.handoffPollInterval = .milliseconds(20) // still polling during the test

        vm.prompt = "/handoff slack"
        await vm.sendPrompt()
        #expect(!vm.isSending) // idle while the handoff settles

        // A message sent now starts a real turn (reaches `prompt`), not the queue.
        vm.prompt = "meanwhile"
        await vm.sendPrompt()
        await wait(for: { backend.promptedContents == ["meanwhile"] },
                   "message sent during handoff was stranded instead of submitted")

        await vm.shutdown() // cancel the still-running detached poll
    }
}

/// Keeps `SessionManager`s alive for a test's duration (the view model holds them
/// weakly). MainActor-isolated, so the plain array needs no extra locking.
@MainActor
final class LiveManagers {
    private var managers: [SessionManager] = []
    func keep(_ manager: SessionManager) { managers.append(manager) }
}

/// A scriptable ``ChatBackend`` recording the native-command RPCs and returning
/// scripted results. Mutable state is guarded by a serial queue so the test
/// (MainActor) and the off-actor async method bodies don't race.
private final class ScriptableChatBackend: ChatBackend, @unchecked Sendable {
    nonisolated let notifications: AsyncThrowingStream<HermesNotification, Error>
    private let continuation: AsyncThrowingStream<HermesNotification, Error>.Continuation
    private let queue = DispatchQueue(label: "ScriptableChatBackend")

    // Scripts (set before the call).
    var backgroundTaskId = "bg_test"
    var branchResult = BranchResult(sessionId: "rt-new", title: "branch", parent: "old")
    var branchError: Error?
    var handoffRequestResult = HandoffRequestResult(queued: true, sessionKey: "k", platform: "p", homeName: "#home")
    var handoffRequestError: Error?
    /// Returned per poll in order; the last entry repeats once exhausted.
    var handoffStates: [HandoffState] = []

    // Recordings.
    private var _promptBackgroundTexts: [String] = []
    private var _promptedContents: [String] = []
    private var _branchNames: [String?] = []
    private var _handoffRequests: [String] = []
    private var _handoffFails: [String] = []
    private var _handoffPolls = 0

    var promptBackgroundTexts: [String] { queue.sync { _promptBackgroundTexts } }
    var promptedContents: [String] { queue.sync { _promptedContents } }
    var branchNames: [String?] { queue.sync { _branchNames } }
    var handoffRequests: [String] { queue.sync { _handoffRequests } }
    var handoffFails: [String] { queue.sync { _handoffFails } }

    init() {
        var captured: AsyncThrowingStream<HermesNotification, Error>.Continuation?
        self.notifications = AsyncThrowingStream { captured = $0 }
        self.continuation = captured!
    }

    func emit(_ notification: HermesNotification) { continuation.yield(notification) }

    func start(clientInfo: Implementation) async throws {}

    func newSession(cwd: String, mcpServers: [McpServer]) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: "scriptable-session")
    }

    func loadSession(sessionId: SessionId, cwd: String, mcpServers: [McpServer]) async throws -> LoadSessionResponse {
        LoadSessionResponse()
    }

    func prompt(sessionId: SessionId, content: [ContentBlock]) async throws -> PromptResponse {
        queue.sync { _promptedContents.append(content.compactMap { $0.plainText }.joined()) }
        return PromptResponse(stopReason: .endTurn)
    }

    func cancel(sessionId: SessionId) async throws {}

    func slash(sessionId: SessionId, command: String) async throws -> SlashOutcome { .output("") }

    func promptBackground(sessionId: SessionId, text: String) async throws -> String {
        queue.sync { _promptBackgroundTexts.append(text) }
        return backgroundTaskId
    }

    func branchSession(sessionId: SessionId, name: String?) async throws -> BranchResult {
        queue.sync { _branchNames.append(name) }
        if let branchError { throw branchError }
        return branchResult
    }

    func requestHandoff(sessionId: SessionId, platform: String) async throws -> HandoffRequestResult {
        queue.sync { _handoffRequests.append(platform) }
        if let handoffRequestError { throw handoffRequestError }
        return handoffRequestResult
    }

    func handoffState(sessionId: SessionId) async throws -> HandoffState {
        let index = queue.sync { () -> Int in
            let i = min(_handoffPolls, max(handoffStates.count - 1, 0))
            _handoffPolls += 1
            return i
        }
        guard !handoffStates.isEmpty else { return HandoffState(state: "", platform: "", error: "") }
        return handoffStates[index]
    }

    func failHandoff(sessionId: SessionId, error: String) async throws {
        queue.sync { _handoffFails.append(error) }
    }

    func respond(id: JSONRPCID, error: JSONRPCError) async throws {}
    func close() async { continuation.finish() }
}

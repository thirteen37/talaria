import Foundation
import Testing
@testable import HermesKit

/// Verifies ``GatewayChatClient`` maps Hermes `/api/ws` gateway frames onto the
/// exact ``HermesNotification`` contract the chat UI consumes — the parity
/// invariant of the ACP→WebSocket migration. Uses a scriptable fake
/// ``GatewayWebSocket`` mirroring the `InMemoryTransport` / `TransportScripter`
/// pattern.
@Suite
struct GatewayChatClientTests {
    // MARK: - Session lifecycle

    @Test
    func newSessionSendsCreateAndReturnsRuntimeId() async throws {
        let fake = FakeGatewayWebSocket()
        let client = GatewayChatClient(webSocket: fake)

        let openTask = Task { try await client.newSession(cwd: "/work") }
        let createFrame = try await fake.waitForSent(at: 0)
        #expect(method(of: createFrame) == "session.create")
        #expect(stringParam(createFrame, "cwd") == "/work")

        fake.pushInbound(responseFrame(id: idOf(createFrame), result: ["session_id": .string("ab12cd34")]))
        let response = try await openTask.value
        #expect(response.sessionId == "ab12cd34")
    }

    @Test
    func newSessionUnderNamedProfileSendsProfileParam() async throws {
        let fake = FakeGatewayWebSocket()
        let client = GatewayChatClient(webSocket: fake, hermesProfileName: "work")

        let openTask = Task { try await client.newSession(cwd: "/work") }
        let createFrame = try await fake.waitForSent(at: 0)
        #expect(method(of: createFrame) == "session.create")
        #expect(stringParam(createFrame, "profile") == "work")

        fake.pushInbound(responseFrame(id: idOf(createFrame), result: ["session_id": .string("ab12cd34")]))
        _ = try await openTask.value
    }

    @Test
    func newSessionUnderDefaultProfileOmitsProfileParam() async throws {
        // Both the explicit "default" name and a nil profile must omit the key —
        // the gateway treats the default profile as the launch home (no-op).
        for name: String? in ["default", nil] {
            let fake = FakeGatewayWebSocket()
            let client = GatewayChatClient(webSocket: fake, hermesProfileName: name)

            let openTask = Task { try await client.newSession(cwd: "/work") }
            let createFrame = try await fake.waitForSent(at: 0)
            #expect(stringParam(createFrame, "profile") == nil)

            fake.pushInbound(responseFrame(id: idOf(createFrame), result: ["session_id": .string("s")]))
            _ = try await openTask.value
        }
    }

    @Test
    func resumeUnderNamedProfileSendsProfileParam() async throws {
        let fake = FakeGatewayWebSocket()
        let client = GatewayChatClient(webSocket: fake, hermesProfileName: "work")

        let openTask = Task { try await client.loadSession(sessionId: "stored-1", cwd: "/work") }
        let resumeFrame = try await fake.waitForSent(at: 0)
        #expect(method(of: resumeFrame) == "session.resume")
        #expect(stringParam(resumeFrame, "profile") == "work")

        fake.pushInbound(responseFrame(id: idOf(resumeFrame), result: ["session_id": .string("rt-1")]))
        _ = try await openTask.value
    }

    @Test
    func loadSessionEmitsUnderBoundIdNotRuntimeId() async throws {
        let (client, fake, _) = try await makeResumedSession(boundId: "stored-99", runtimeId: "rt-7")

        // An event tagged with the gateway's runtime id must still surface under
        // the id the UI registered (the stored id).
        var iterator = client.notifications.makeAsyncIterator()
        fake.pushInbound(eventFrame(type: "message.delta", sessionId: "rt-7", payload: ["text": .string("hi")]))
        let note = try await requireNext(&iterator)
        guard case let .sessionUpdate(update) = note else {
            Issue.record("expected sessionUpdate, got \(note)")
            return
        }
        #expect(update.sessionId == "stored-99")
    }

    // MARK: - Streaming mapping

    @Test
    func messageDeltaMapsToAgentMessageChunk() async throws {
        let (client, fake, sid) = try await makeReadySession()
        var iterator = client.notifications.makeAsyncIterator()

        fake.pushInbound(eventFrame(type: "message.delta", sessionId: sid, payload: ["text": .string("Hello")]))
        let note = try await requireNext(&iterator)
        #expect(note == .sessionUpdate(SessionNotification(
            sessionId: sid,
            update: .agentMessageChunk(Content(content: .text("Hello")))
        )))
    }

    @Test
    func reasoningDeltaMapsToThoughtChunk() async throws {
        let (client, fake, sid) = try await makeReadySession()
        var iterator = client.notifications.makeAsyncIterator()

        fake.pushInbound(eventFrame(type: "reasoning.delta", sessionId: sid, payload: ["text": .string("pondering")]))
        let note = try await requireNext(&iterator)
        #expect(note == .sessionUpdate(SessionNotification(
            sessionId: sid,
            update: .agentThoughtChunk(Content(content: .text("pondering")))
        )))
    }

    @Test
    func reasoningAvailableSuppressedAfterDelta() async throws {
        // After a reasoning.delta streamed, the full-text reasoning.available is
        // dropped (append-only stream would otherwise duplicate the reasoning).
        // Push delta → available → a message.delta marker, and assert only the
        // delta + marker surface.
        let (client, fake, sid) = try await makeReadySession()
        var iterator = client.notifications.makeAsyncIterator()

        fake.pushInbound(eventFrame(type: "reasoning.delta", sessionId: sid, payload: ["text": .string("step ")]))
        fake.pushInbound(eventFrame(type: "reasoning.available", sessionId: sid, payload: ["text": .string("step one and two")]))
        fake.pushInbound(eventFrame(type: "message.delta", sessionId: sid, payload: ["text": .string("answer")]))

        let first = try await requireNext(&iterator)
        #expect(first == .sessionUpdate(SessionNotification(
            sessionId: sid, update: .agentThoughtChunk(Content(content: .text("step ")))
        )))
        let second = try await requireNext(&iterator)
        #expect(second == .sessionUpdate(SessionNotification(
            sessionId: sid, update: .agentMessageChunk(Content(content: .text("answer")))
        )))
    }

    @Test
    func reasoningAvailableEmittedWhenNoDelta() async throws {
        // Some models emit only reasoning.available (no deltas) — it must surface.
        let (client, fake, sid) = try await makeReadySession()
        var iterator = client.notifications.makeAsyncIterator()

        fake.pushInbound(eventFrame(type: "reasoning.available", sessionId: sid, payload: ["text": .string("full reasoning")]))
        let note = try await requireNext(&iterator)
        #expect(note == .sessionUpdate(SessionNotification(
            sessionId: sid, update: .agentThoughtChunk(Content(content: .text("full reasoning")))
        )))
    }

    @Test
    func thinkingDeltaIsIgnored() async throws {
        let (client, fake, sid) = try await makeReadySession()
        var iterator = client.notifications.makeAsyncIterator()

        // thinking.delta is the kawaii spinner status — must NOT surface. Push it,
        // then a real delta, and assert only the real one arrives.
        fake.pushInbound(eventFrame(type: "thinking.delta", sessionId: sid, payload: ["text": .string("spinner")]))
        fake.pushInbound(eventFrame(type: "message.delta", sessionId: sid, payload: ["text": .string("real")]))
        let note = try await requireNext(&iterator)
        #expect(note == .sessionUpdate(SessionNotification(
            sessionId: sid,
            update: .agentMessageChunk(Content(content: .text("real")))
        )))
    }

    @Test
    func toolStartAndCompleteMapToToolCallAndUpdate() async throws {
        let (client, fake, sid) = try await makeReadySession()
        var iterator = client.notifications.makeAsyncIterator()

        fake.pushInbound(eventFrame(type: "tool.start", sessionId: sid, payload: [
            "tool_id": .string("call-1"), "name": .string("read_file")
        ]))
        let startNote = try await requireNext(&iterator)
        guard case let .sessionUpdate(s1) = startNote, case let .toolCall(toolCall) = s1.update else {
            Issue.record("expected toolCall, got \(startNote)")
            return
        }
        #expect(toolCall.toolCallId == "call-1")
        #expect(toolCall.title == "read_file")
        #expect(toolCall.status == .inProgress)

        fake.pushInbound(eventFrame(type: "tool.complete", sessionId: sid, payload: [
            "tool_id": .string("call-1"), "name": .string("read_file"), "result": .string("ok")
        ]))
        let doneNote = try await requireNext(&iterator)
        guard case let .sessionUpdate(s2) = doneNote, case let .toolCallUpdate(update) = s2.update else {
            Issue.record("expected toolCallUpdate, got \(doneNote)")
            return
        }
        #expect(update.toolCallId == "call-1")
        #expect(update.status == .completed)
    }

    @Test
    func toolCompleteInlineDiffMapsToDiffContent() async throws {
        let (client, fake, sid) = try await makeReadySession()
        var iterator = client.notifications.makeAsyncIterator()

        fake.pushInbound(eventFrame(type: "tool.complete", sessionId: sid, payload: [
            "tool_id": .string("call-2"),
            "name": .string("patch"),
            "inline_diff": .string("- old\n+ new")
        ]))
        let note = try await requireNext(&iterator)
        guard case let .sessionUpdate(s) = note,
              case let .toolCallUpdate(update) = s.update,
              case let .diff(diff)? = update.content?.first else {
            Issue.record("expected diff content, got \(note)")
            return
        }
        #expect(diff.newText == "- old\n+ new")
    }

    // MARK: - Turn lifecycle

    @Test
    func promptResolvesOnMessageComplete() async throws {
        let (client, fake, sid) = try await makeReadySession()
        let sentBefore = fake.sent.count

        let promptTask = Task { try await client.prompt(sessionId: sid, content: "do it") }

        let submitFrame = try await fake.waitForSent(at: sentBefore)
        #expect(method(of: submitFrame) == "prompt.submit")
        #expect(stringParam(submitFrame, "text") == "do it")
        // Ack, then completion.
        fake.pushInbound(responseFrame(id: idOf(submitFrame), result: ["status": .string("streaming")]))
        fake.pushInbound(eventFrame(type: "message.complete", sessionId: sid, payload: ["status": .string("complete")]))

        let response = try await promptTask.value
        #expect(response.stopReason == .endTurn)
    }

    @Test
    func interruptedCompletionMapsToCancelledStopReason() async throws {
        let (client, fake, sid) = try await makeReadySession()
        let sentBefore = fake.sent.count
        let promptTask = Task { try await client.prompt(sessionId: sid, content: "x") }
        let submitFrame = try await fake.waitForSent(at: sentBefore)
        fake.pushInbound(responseFrame(id: idOf(submitFrame), result: ["status": .string("streaming")]))
        fake.pushInbound(eventFrame(type: "message.complete", sessionId: sid, payload: ["status": .string("interrupted")]))

        let response = try await promptTask.value
        #expect(response.stopReason == .cancelled)
    }

    @Test
    func messageCompleteErrorStatusFailsPrompt() async throws {
        // A turn that completes with status:"error" and no preceding error event
        // must surface as a failure, not a clean end_turn.
        let (client, fake, sid) = try await makeReadySession()
        let sentBefore = fake.sent.count
        let promptTask = Task { try await client.prompt(sessionId: sid, content: "x") }
        let submitFrame = try await fake.waitForSent(at: sentBefore)
        fake.pushInbound(responseFrame(id: idOf(submitFrame), result: ["status": .string("streaming")]))
        fake.pushInbound(eventFrame(type: "message.complete", sessionId: sid, payload: [
            "status": .string("error"), "text": .string("provider 500")
        ]))

        await #expect(throws: GatewayChatError.self) {
            _ = try await promptTask.value
        }
    }

    @Test
    func cancelSendsInterrupt() async throws {
        let (client, fake, sid) = try await makeReadySession()
        let sentBefore = fake.sent.count

        async let _: Void = client.cancel(sessionId: sid)
        let frame = try await fake.waitForSent(at: sentBefore)
        #expect(method(of: frame) == "session.interrupt")
    }

    // MARK: - Permissions

    @Test
    func approvalRequestRoundTrips() async throws {
        let (client, fake, sid) = try await makeReadySession()
        var iterator = client.notifications.makeAsyncIterator()

        fake.pushInbound(eventFrame(type: "approval.request", sessionId: sid, payload: [
            "command": .string("rm -rf /"), "description": .string("dangerous command")
        ]))
        let note = try await requireNext(&iterator)
        guard case let .permissionRequest(event) = note else {
            Issue.record("expected permissionRequest, got \(note)")
            return
        }
        #expect(event.kind == .permission)
        #expect(event.request.options.contains { $0.optionId == "once" })
        #expect(event.request.options.contains { $0.optionId == "deny" })

        let sentBefore = fake.sent.count
        await event.respond(.selected(SelectedPermissionOutcome(optionId: "once")))
        let respondFrame = try await fake.waitForSent(at: sentBefore)
        #expect(method(of: respondFrame) == "approval.respond")
        #expect(stringParam(respondFrame, "choice") == "once")
    }

    @Test
    func clarifyRequestRoundTrips() async throws {
        let (client, fake, sid) = try await makeReadySession()
        var iterator = client.notifications.makeAsyncIterator()

        fake.pushInbound(eventFrame(type: "clarify.request", sessionId: sid, payload: [
            "request_id": .string("clar-1"),
            "question": .string("Where are you looking to dine?"),
            "choices": .array([.string("Garden"), .string("Patio"), .string("Bar"), .string("Main hall")])
        ]))
        let note = try await requireNext(&iterator)
        guard case let .permissionRequest(event) = note else {
            Issue.record("expected permissionRequest, got \(note)")
            return
        }
        #expect(event.kind == .question)
        #expect(event.request.toolCall.title == "Where are you looking to dine?")
        #expect(event.request.options.map(\.name) == ["Garden", "Patio", "Bar", "Main hall"])

        let sentBefore = fake.sent.count
        await event.respond(.selected(SelectedPermissionOutcome(optionId: "Patio")))
        let respondFrame = try await fake.waitForSent(at: sentBefore)
        #expect(method(of: respondFrame) == "clarify.respond")
        #expect(stringParam(respondFrame, "answer") == "Patio")
    }

    @Test
    func errorEventDuringTurnFailsPrompt() async throws {
        let (client, fake, sid) = try await makeReadySession()
        let sentBefore = fake.sent.count
        let promptTask = Task { try await client.prompt(sessionId: sid, content: "x") }
        let submitFrame = try await fake.waitForSent(at: sentBefore)
        fake.pushInbound(responseFrame(id: idOf(submitFrame), result: ["status": .string("streaming")]))
        fake.pushInbound(eventFrame(type: "error", sessionId: sid, payload: ["message": .string("boom")]))

        await #expect(throws: GatewayChatError.self) {
            _ = try await promptTask.value
        }
    }

    // MARK: - Slash commands

    @Test
    func slashExecResolvesToOutput() async throws {
        let (client, fake, sid) = try await makeReadySession()
        let sentBefore = fake.sent.count

        let task = Task { try await client.slash(sessionId: sid, command: "/help") }
        let frame = try await fake.waitForSent(at: sentBefore)
        #expect(method(of: frame) == "slash.exec")
        // The leading slash is stripped before hitting the harness slash worker.
        #expect(stringParam(frame, "command") == "help")
        #expect(stringParam(frame, "session_id") == sid)

        fake.pushInbound(responseFrame(id: idOf(frame), result: ["output": .string("commands: /help …")]))
        let outcome = try await task.value
        #expect(outcome == .output("commands: /help …"))
    }

    @Test
    func slashUndoDispatchesDirectlyToCommandDispatchPrefill() async throws {
        // `/undo` is pending-input, so it goes straight to `command.dispatch`
        // (NOT `slash.exec` first) — some Hermes versions return empty-output
        // success from `slash.exec` for these, which would silently no-op the
        // command. `command.dispatch` returns the `prefill` rewind shape.
        let (client, fake, sid) = try await makeReadySession()
        let sentBefore = fake.sent.count

        let task = Task { try await client.slash(sessionId: sid, command: "/undo") }
        let dispatchFrame = try await fake.waitForSent(at: sentBefore)
        #expect(method(of: dispatchFrame) == "command.dispatch")
        #expect(stringParam(dispatchFrame, "name") == "undo")
        fake.pushInbound(responseFrame(id: idOf(dispatchFrame), result: [
            "type": .string("prefill"),
            "message": .string("prev"),
            "notice": .string("↶ Undid 1 turn…")
        ]))

        let outcome = try await task.value
        #expect(outcome == .prefill(message: "prev", notice: "↶ Undid 1 turn…"))
    }

    @Test
    func slashRetryDispatchesDirectlyToCommandDispatch() async throws {
        // `/retry` is pending-input: it must reach `command.dispatch` directly so
        // it actually retries, rather than going through `slash.exec` (which a
        // Hermes version may answer with empty output, rendering "(no output)"
        // and never retrying). Hermes resolves `/retry` as a `send` (resubmit).
        let (client, fake, sid) = try await makeReadySession()
        let sentBefore = fake.sent.count

        let task = Task { try await client.slash(sessionId: sid, command: "/retry") }
        let dispatchFrame = try await fake.waitForSent(at: sentBefore)
        #expect(method(of: dispatchFrame) == "command.dispatch")
        #expect(stringParam(dispatchFrame, "name") == "retry")
        fake.pushInbound(responseFrame(id: idOf(dispatchFrame), result: [
            "type": .string("send"),
            "message": .string("the previous prompt")
        ]))

        let outcome = try await task.value
        #expect(outcome == .submit(message: "the previous prompt", notice: nil))
    }

    @Test
    func commandDispatchSendResolvesToSubmit() async throws {
        // `/q` is pending-input → dispatched directly (no `slash.exec` first).
        let (client, fake, sid) = try await makeReadySession()
        let sentBefore = fake.sent.count

        let task = Task { try await client.slash(sessionId: sid, command: "/q hello there") }
        let dispatchFrame = try await fake.waitForSent(at: sentBefore)
        #expect(method(of: dispatchFrame) == "command.dispatch")
        #expect(stringParam(dispatchFrame, "name") == "q")
        #expect(stringParam(dispatchFrame, "arg") == "hello there")
        fake.pushInbound(responseFrame(id: idOf(dispatchFrame), result: [
            "type": .string("send"),
            "message": .string("hello there")
        ]))

        let outcome = try await task.value
        #expect(outcome == .submit(message: "hello there", notice: nil))
    }

    @Test
    func commandDispatchSkillResolvesToSubmitWithNotice() async throws {
        let (client, fake, sid) = try await makeReadySession()
        let sentBefore = fake.sent.count

        let task = Task { try await client.slash(sessionId: sid, command: "/brainstorm") }
        let execFrame = try await fake.waitForSent(at: sentBefore)
        fake.pushInbound(errorFrame(id: idOf(execFrame), message: "needs dispatch"))

        let dispatchFrame = try await fake.waitForSent(at: sentBefore + 1)
        fake.pushInbound(responseFrame(id: idOf(dispatchFrame), result: [
            "type": .string("skill"),
            "name": .string("brainstorm"),
            "message": .string("Use the brainstorm skill")
        ]))

        let outcome = try await task.value
        #expect(outcome == .submit(message: "Use the brainstorm skill", notice: "⚡ loading skill: brainstorm"))
    }

    @Test
    func commandDispatchAliasRecursesToTarget() async throws {
        let (client, fake, sid) = try await makeReadySession()
        let sentBefore = fake.sent.count

        let task = Task { try await client.slash(sessionId: sid, command: "/h") }
        let execFrame = try await fake.waitForSent(at: sentBefore)
        fake.pushInbound(errorFrame(id: idOf(execFrame), message: "needs dispatch"))

        let dispatchFrame = try await fake.waitForSent(at: sentBefore + 1)
        fake.pushInbound(responseFrame(id: idOf(dispatchFrame), result: [
            "type": .string("alias"),
            "target": .string("help")
        ]))

        // The alias recurses through `slash`, so the aliased target runs through
        // `slash.exec` again.
        let aliasExecFrame = try await fake.waitForSent(at: sentBefore + 2)
        #expect(method(of: aliasExecFrame) == "slash.exec")
        #expect(stringParam(aliasExecFrame, "command") == "help")
        fake.pushInbound(responseFrame(id: idOf(aliasExecFrame), result: ["output": .string("help text")]))

        let outcome = try await task.value
        #expect(outcome == .output("help text"))
    }

    @Test
    func slashDoesNotEmitPromptSubmitOrBlockTheTurn() async throws {
        let (client, fake, sid) = try await makeReadySession()
        let sentBefore = fake.sent.count

        let slashTask = Task { try await client.slash(sessionId: sid, command: "/status") }
        let execFrame = try await fake.waitForSent(at: sentBefore)
        #expect(method(of: execFrame) == "slash.exec")
        fake.pushInbound(responseFrame(id: idOf(execFrame), result: ["output": .string("ok")]))
        _ = try await slashTask.value

        // A normal prompt still works afterwards — slash never touched the turn
        // continuation.
        let beforePrompt = fake.sent.count
        let promptTask = Task { try await client.prompt(sessionId: sid, content: "go") }
        let submitFrame = try await fake.waitForSent(at: beforePrompt)
        #expect(method(of: submitFrame) == "prompt.submit")
        fake.pushInbound(responseFrame(id: idOf(submitFrame), result: ["status": .string("streaming")]))
        fake.pushInbound(eventFrame(type: "message.complete", sessionId: sid, payload: ["status": .string("complete")]))
        let response = try await promptTask.value
        #expect(response.stopReason == .endTurn)
    }

    @Test
    func setTitleSendsSessionTitleAndReturnsResolved() async throws {
        let (client, fake, sid) = try await makeReadySession()
        let sentBefore = fake.sent.count

        let task = Task { try await client.setTitle(sessionId: sid, title: "Foo") }
        let frame = try await fake.waitForSent(at: sentBefore)
        #expect(method(of: frame) == "session.title")
        #expect(stringParam(frame, "title") == "Foo")
        #expect(stringParam(frame, "session_id") == sid)

        fake.pushInbound(responseFrame(id: idOf(frame), result: [
            "title": .string("Foo"),
            "pending": .bool(true)
        ]))
        let resolved = try await task.value
        #expect(resolved == "Foo")
    }

    // MARK: - Helpers

    /// Awaits the next notification and requires it to be non-nil. Evaluates
    /// `next()` outside `#require` on purpose: the macro captures its receiver
    /// immutably, so `#require(iterator.next())` rejects the mutating
    /// `AsyncIterator.next()` on stricter swift-testing toolchains (CI).
    private func requireNext(
        _ iterator: inout AsyncThrowingStream<HermesNotification, Error>.Iterator
    ) async throws -> HermesNotification {
        let value = try await iterator.next()
        return try #require(value)
    }

    private func makeReadySession() async throws -> (GatewayChatClient, FakeGatewayWebSocket, SessionId) {
        let fake = FakeGatewayWebSocket()
        let client = GatewayChatClient(webSocket: fake)
        let openTask = Task { try await client.newSession(cwd: "/work") }
        let createFrame = try await fake.waitForSent(at: 0)
        fake.pushInbound(responseFrame(id: idOf(createFrame), result: ["session_id": .string("sess-1")]))
        let response = try await openTask.value
        // Session open now also fetches the slash-command catalog (fire-and-forget);
        // drain that frame so callers' positional frame indexing is deterministic.
        let catalogFrame = try await fake.waitForSent(at: 1)
        #expect(method(of: catalogFrame) == "commands.catalog")
        return (client, fake, response.sessionId)
    }

    private func makeResumedSession(
        boundId: String,
        runtimeId: String
    ) async throws -> (GatewayChatClient, FakeGatewayWebSocket, SessionId) {
        let fake = FakeGatewayWebSocket()
        let client = GatewayChatClient(webSocket: fake)
        let openTask = Task { try await client.loadSession(sessionId: boundId, cwd: "/work") }
        let resumeFrame = try await fake.waitForSent(at: 0)
        #expect(method(of: resumeFrame) == "session.resume")
        fake.pushInbound(responseFrame(id: idOf(resumeFrame), result: [
            "session_id": .string(runtimeId), "resumed": .string(boundId)
        ]))
        _ = try await openTask.value
        // Resume also fetches the slash-command catalog; drain it for deterministic indexing.
        let catalogFrame = try await fake.waitForSent(at: 1)
        #expect(method(of: catalogFrame) == "commands.catalog")
        return (client, fake, boundId)
    }

    // Frame builders / parsers ------------------------------------------------

    private func responseFrame(id: String, result: [String: JSONValue]) -> Data {
        encode(.object([
            "jsonrpc": .string("2.0"),
            "id": .string(id),
            "result": .object(result)
        ]))
    }

    private func errorFrame(id: String, message: String) -> Data {
        encode(.object([
            "jsonrpc": .string("2.0"),
            "id": .string(id),
            "error": .object(["message": .string(message)])
        ]))
    }

    private func eventFrame(type: String, sessionId: String, payload: [String: JSONValue]) -> Data {
        encode(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("event"),
            "params": .object([
                "type": .string(type),
                "session_id": .string(sessionId),
                "payload": .object(payload)
            ])
        ]))
    }

    private func encode(_ value: JSONValue) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    private func decode(_ data: Data) -> [String: JSONValue] {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .object(object) = value else { return [:] }
        return object
    }

    private func method(of frame: Data) -> String? {
        if case let .string(m)? = decode(frame)["method"] { return m }
        return nil
    }

    private func idOf(_ frame: Data) -> String {
        if case let .string(i)? = decode(frame)["id"] { return i }
        return ""
    }

    private func stringParam(_ frame: Data, _ key: String) -> String? {
        guard case let .object(params)? = decode(frame)["params"],
              case let .string(value)? = params[key] else { return nil }
        return value
    }
}

/// Scriptable fake mirroring `InMemoryTransport`: tests push inbound frames and
/// inspect what the client sent.
final class FakeGatewayWebSocket: GatewayWebSocket, @unchecked Sendable {
    nonisolated let messages: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let queue = DispatchQueue(label: "FakeGatewayWebSocket")
    private var _sent: [Data] = []

    init() {
        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        self.messages = AsyncThrowingStream { captured = $0 }
        self.continuation = captured!
    }

    func send(_ data: Data) async throws {
        queue.sync { _sent.append(data) }
    }

    func close() async {
        continuation.finish()
    }

    nonisolated func pushInbound(_ data: Data) {
        continuation.yield(data)
    }

    nonisolated func finishInbound(throwing error: Error? = nil) {
        continuation.finish(throwing: error)
    }

    var sent: [Data] { queue.sync { _sent } }

    /// Polls until at least `position + 1` frames have been sent, returning the
    /// frame at `position`. Mirrors `TransportScripter.waitForFrame`.
    func waitForSent(at position: Int) async throws -> Data {
        for _ in 0..<200 {
            if let frame = queue.sync(execute: { _sent.count > position ? _sent[position] : nil }) {
                return frame
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw FakeError.noFrame
    }

    enum FakeError: Error { case noFrame }
}

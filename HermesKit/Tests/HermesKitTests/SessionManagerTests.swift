import Foundation
import Testing
@testable import HermesKit

@Suite
struct SessionManagerTests {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test
    func openNewIssuesInitializeAndSessionNew() async throws {
        let scripter = TransportScripter()
        let manager = SessionManager { await scripter.next() }

        let openTask = Task { try await manager.openNew(cwd: "/tmp/one") }

        try await scripter.respondToInitialize()
        try await scripter.respondToNewSession(sessionId: "abc")

        let state = try await openTask.value
        #expect(state.id == "abc")
        #expect(state.cwd == "/tmp/one")
    }

    @Test
    func backendKindReportsACPForTransportBackedSession() async throws {
        let scripter = TransportScripter()
        let manager = SessionManager { await scripter.next() }

        let openTask = Task { try await manager.openNew(cwd: "/tmp") }
        try await scripter.respondToInitialize()
        try await scripter.respondToNewSession(sessionId: "abc")
        _ = try await openTask.value

        #expect(await manager.backendKind(for: "abc") == .acp)
        #expect(await manager.backendKind(for: "missing") == nil)
    }

    @Test
    func backendKindReportsGatewayForGatewayBackedSession() async throws {
        // A SessionManager whose factory yields a GatewayChatClient reports
        // `.gateway`, so the chat UI's badge reflects the WS path.
        let socket = FakeGatewayWebSocket()
        let manager = SessionManager(backendFactory: { GatewayChatClient(webSocket: socket) })

        let openTask = Task { try await manager.openNew(cwd: "/tmp") }
        // Respond to the session.create the gateway client sends.
        let frame = try await socket.waitForSent(at: 0)
        socket.pushInbound(gatewayResponse(id: frame, sessionId: "rt-1"))
        let state = try await openTask.value

        #expect(await manager.backendKind(for: state.id) == .gateway)
    }

    /// Builds a `{jsonrpc,id,result:{session_id}}` response for the id in `frame`.
    private func gatewayResponse(id frame: Data, sessionId: String) -> Data {
        let object = (try? JSONDecoder().decode(JSONValue.self, from: frame)).flatMap { value -> String? in
            if case let .object(o) = value, case let .string(id)? = o["id"] { return id }
            return nil
        } ?? ""
        let response = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .string(object),
            "result": .object(["session_id": .string(sessionId)])
        ])
        return (try? JSONEncoder().encode(response)) ?? Data()
    }

    @Test
    func openExistingIssuesSessionLoad() async throws {
        let scripter = TransportScripter()
        let manager = SessionManager { await scripter.next() }

        let openTask = Task { try await manager.openExisting(id: "session-1", cwd: "/tmp/proj") }

        try await scripter.respondToInitialize()
        try await scripter.respondToLoadSession()

        let state = try await openTask.value
        #expect(state.id == "session-1")
    }

    @Test
    func notificationsBufferedBeforeSubscriberAttachedAreReplayed() async throws {
        // Regression: when SessionsStore resumes a session, hermes streams
        // the historical transcript as `session/update` notifications during
        // `session/load`. The chat view model subscribes only *after* the
        // load completes, so without a replay buffer those notifications
        // were fanned out to zero subscribers and dropped — the resumed
        // session showed up empty.
        let scripter = TransportScripter()
        let manager = SessionManager { await scripter.next() }

        let openTask = Task { try await manager.openExisting(id: "sess", cwd: "/tmp") }
        try await scripter.respondToInitialize()
        try await scripter.respondToLoadSession()
        let state = try await openTask.value

        // Push two historical updates before any subscriber attaches.
        let first = SessionNotification(
            sessionId: state.id,
            update: .userMessageChunk(Content(content: .text("hi from past")))
        )
        let second = SessionNotification(
            sessionId: state.id,
            update: .agentMessageChunk(Content(content: .text("hello from past")))
        )
        let transports = await scripter.transports
        let transport = try #require(transports.first)
        transport.pushInbound(try JSONRPCFramer.encode(
            JSONRPCNotification(method: ACPMethod.sessionUpdate, params: first)
        ))
        transport.pushInbound(try JSONRPCFramer.encode(
            JSONRPCNotification(method: ACPMethod.sessionUpdate, params: second)
        ))
        // Let the pump deliver them to the (empty) subscriber set.
        try await Task.sleep(nanoseconds: 50_000_000)

        // Attach a late subscriber and expect both buffered notifications
        // in send order.
        let stream = await manager.notifications(for: state.id)
        var iterator = stream.makeAsyncIterator()
        let receivedFirst = await iterator.next()
        let receivedSecond = await iterator.next()

        #expect(receivedFirst == .sessionUpdate(first))
        #expect(receivedSecond == .sessionUpdate(second))
    }

    @Test
    func notificationsFanOutToMultipleSubscribers() async throws {
        let scripter = TransportScripter()
        let manager = SessionManager { await scripter.next() }

        let openTask = Task { try await manager.openNew(cwd: "/tmp/x") }
        try await scripter.respondToInitialize()
        try await scripter.respondToNewSession(sessionId: "sess")
        let state = try await openTask.value

        let streamA = await manager.notifications(for: state.id)
        let streamB = await manager.notifications(for: state.id)

        try await Task.sleep(nanoseconds: 50_000_000)

        let notification = SessionNotification(
            sessionId: state.id,
            update: .agentMessageChunk(Content(content: .text("hello")))
        )
        let frame = try JSONRPCFramer.encode(JSONRPCNotification(method: ACPMethod.sessionUpdate, params: notification))
        let transports = await scripter.transports
        let transport = try #require(transports.first)
        transport.pushInbound(frame)

        var iterA = streamA.makeAsyncIterator()
        var iterB = streamB.makeAsyncIterator()
        let receivedA = await iterA.next()
        let receivedB = await iterB.next()

        #expect(receivedA == .sessionUpdate(notification))
        #expect(receivedB == .sessionUpdate(notification))
    }

    @Test
    func concurrentOpenExistingForSameIdResolvesToOneRegistration() async throws {
        let scripter = TransportScripter()
        let manager = SessionManager { await scripter.next() }

        // Two parallel openExisting calls for the same session id. Both will
        // boot fresh transports and issue initialize + session/load; only one
        // may end up registered. Without the post-await re-check inside
        // openExisting, the second call would silently overwrite the first
        // and leak the original client.
        let firstTask = Task { try await manager.openExisting(id: "shared-id", cwd: "/tmp/a") }
        let secondTask = Task { try await manager.openExisting(id: "shared-id", cwd: "/tmp/b") }

        let firstTransport = try await scripter.waitForTransport(at: 0)
        let secondTransport = try await scripter.waitForTransport(at: 1)
        try await scripter.respondToInitialize(on: firstTransport)
        try await scripter.respondToInitialize(on: secondTransport)
        try await scripter.respondToLoadSession(on: firstTransport)
        try await scripter.respondToLoadSession(on: secondTransport)

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
    func closeFinishesSubscribersAndDropsClient() async throws {
        let scripter = TransportScripter()
        let manager = SessionManager { await scripter.next() }

        let openTask = Task { try await manager.openNew(cwd: "/tmp/x") }
        try await scripter.respondToInitialize()
        try await scripter.respondToNewSession(sessionId: "sess")
        let state = try await openTask.value

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

private actor TransportScripter {
    var transports: [InMemoryTransport] = []
    private var frameIndex: [ObjectIdentifier: Int] = [:]

    func next() async -> any Transport {
        let transport = InMemoryTransport()
        transports.append(transport)
        return transport
    }

    func waitForTransport(at position: Int) async throws -> InMemoryTransport {
        for _ in 0..<200 {
            if transports.count > position {
                return transports[position]
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ScripterError.noTransport
    }

    func respondToInitialize() async throws {
        let transport = try await latest()
        try await respondToInitialize(on: transport)
    }

    func respondToInitialize(on transport: InMemoryTransport) async throws {
        let frame = try await waitForFrame(transport)
        let request = try JSONDecoder().decode(JSONRPCRequest<JSONValue>.self, from: frame.dropLastNewline())
        let response = InitializeResponse(protocolVersion: 1, agentCapabilities: AgentCapabilities())
        transport.pushInbound(try JSONRPCFramer.encode(JSONRPCResponse(id: request.id, result: response)))
    }

    func respondToNewSession(sessionId: SessionId) async throws {
        let transport = try await latest()
        let frame = try await waitForFrame(transport)
        let request = try JSONDecoder().decode(JSONRPCRequest<JSONValue>.self, from: frame.dropLastNewline())
        transport.pushInbound(try JSONRPCFramer.encode(JSONRPCResponse(id: request.id, result: NewSessionResponse(sessionId: sessionId))))
    }

    func respondToLoadSession() async throws {
        let transport = try await latest()
        try await respondToLoadSession(on: transport)
    }

    func respondToLoadSession(on transport: InMemoryTransport) async throws {
        let frame = try await waitForFrame(transport)
        let request = try JSONDecoder().decode(JSONRPCRequest<JSONValue>.self, from: frame.dropLastNewline())
        transport.pushInbound(try JSONRPCFramer.encode(JSONRPCResponse(id: request.id, result: LoadSessionResponse())))
    }

    private func latest() async throws -> InMemoryTransport {
        for _ in 0..<200 {
            if let transport = transports.last {
                return transport
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ScripterError.noTransport
    }

    private func waitForFrame(_ transport: InMemoryTransport) async throws -> Data {
        let key = ObjectIdentifier(transport)
        for _ in 0..<200 {
            let data = await transport.sentData()
            let consumed = frameIndex[key, default: 0]
            if data.count > consumed {
                frameIndex[key] = consumed + 1
                return data[consumed]
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ScripterError.timeout
    }

    enum ScripterError: Error {
        case noTransport
        case timeout
    }
}

private extension Data {
    func dropLastNewline() -> Data {
        guard last == 0x0A else { return self }
        return Data(dropLast())
    }
}

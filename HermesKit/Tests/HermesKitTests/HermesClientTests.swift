import Foundation
import Testing
@testable import HermesKit

@Suite
struct HermesClientTests {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test
    func initializeReturnsTypedResponse() async throws {
        let transport = InMemoryTransport()
        let client = HermesClient(transport: transport)

        let task = Task {
            try await client.initialize()
        }

        let requests = try await waitForSentData(transport, count: 1)
        let request = try decodeRequest(requests[0])
        #expect(request.method == ACPMethod.initialize)

        let response = InitializeResponse(
            protocolVersion: 1,
            agentCapabilities: AgentCapabilities(),
            agentInfo: Implementation(name: "Hermes", version: "0.1")
        )
        transport.pushInbound(try JSONRPCFramer.encode(JSONRPCResponse(id: request.id, result: response)))

        let result = try await task.value
        #expect(result.protocolVersion == 1)
        #expect(result.agentInfo?.name == "Hermes")
    }

    @Test
    func correlatesResponsesOutOfOrder() async throws {
        let transport = InMemoryTransport()
        let client = HermesClient(transport: transport)

        let first = Task {
            try await client.newSession(cwd: "/tmp/one")
        }
        let second = Task {
            try await client.newSession(cwd: "/tmp/two")
        }

        let requests = try await waitForSentData(transport, count: 2)
        let firstRequest = try decodeRequest(requests[0])
        let secondRequest = try decodeRequest(requests[1])

        transport.pushInbound(try JSONRPCFramer.encode(JSONRPCResponse(id: secondRequest.id, result: NewSessionResponse(sessionId: "two"))))
        transport.pushInbound(try JSONRPCFramer.encode(JSONRPCResponse(id: firstRequest.id, result: NewSessionResponse(sessionId: "one"))))

        #expect(try await first.value.sessionId == "one")
        #expect(try await second.value.sessionId == "two")
    }

    @Test
    func propagatesJSONRPCErrors() async throws {
        let transport = InMemoryTransport()
        let client = HermesClient(transport: transport)

        let task = Task {
            try await client.newSession(cwd: "/tmp")
        }

        let sent = try await waitForSentData(transport, count: 1)
        let request = try decodeRequest(sent[0])
        transport.pushInbound(try JSONRPCFramer.encode(JSONRPCResponse<JSONValue>(id: request.id, error: JSONRPCError(code: -32000, message: "nope"))))

        await #expect(throws: JSONRPCError(code: -32000, message: "nope")) {
            try await task.value
        }
    }

    @Test
    func nullResultIsSuccessfulJSONRPCResponse() async throws {
        let transport = InMemoryTransport()
        let client = HermesClient(transport: transport)

        let task = Task {
            try await client.request(method: "void/method", params: JSONValue?.none, as: JSONValue.self)
        }

        let sent = try await waitForSentData(transport, count: 1)
        let request = try decodeRequest(sent[0])
        let idData = try JSONEncoder().encode(request.id)
        let id = String(decoding: idData, as: UTF8.self)
        transport.pushInbound(Data(#"{"jsonrpc":"2.0","id":"# .utf8))
        transport.pushInbound(Data(id.utf8))
        transport.pushInbound(Data(#","result":null}"# .utf8 + [0x0A]))

        let result = try await task.value
        #expect(result == .null)
    }

    @Test
    func streamsTypedSessionUpdateNotifications() async throws {
        let transport = InMemoryTransport()
        let client = HermesClient(transport: transport)

        var iterator = client.notifications.makeAsyncIterator()
        let nextNotification = Task {
            try await iterator.next()
        }

        let notification = SessionNotification(
            sessionId: "session-1",
            update: .agentMessageChunk(Content(content: .text("hello")))
        )
        transport.pushInbound(try JSONRPCFramer.encode(JSONRPCNotification(method: ACPMethod.sessionUpdate, params: notification)))

        let received = try await nextNotification.value
        #expect(received == .sessionUpdate(notification))
    }

    @Test
    func serverRequestsAreNotCorrelatedAsResponses() async throws {
        let transport = InMemoryTransport()
        let client = HermesClient(transport: transport)

        var iterator = client.notifications.makeAsyncIterator()
        let nextNotification = Task {
            try await iterator.next()
        }

        let task = Task {
            try await client.newSession(cwd: "/tmp")
        }

        let sent = try await waitForSentData(transport, count: 1)
        let request = try decodeRequest(sent[0])
        transport.pushInbound(try JSONRPCFramer.encode(JSONRPCRequest(
            id: request.id,
            method: ACPMethod.fsReadTextFile,
            params: ReadTextFileRequest(path: "/tmp/file")
        )))

        let received = try await nextNotification.value
        #expect(received == .request(
            id: request.id,
            method: ACPMethod.fsReadTextFile,
            params: .object(["path": .string("/tmp/file")])
        ))

        try await client.respond(id: request.id, error: JSONRPCError(code: -32601, message: "unsupported"))
        let responseFrames = try await waitForSentData(transport, count: 2)
        let response = try decoder.decode(JSONRPCInboundMessage.self, from: responseFrames[1].dropLastNewline())
        #expect(response.id == request.id)
        #expect(response.error == JSONRPCError(code: -32601, message: "unsupported"))

        transport.pushInbound(try JSONRPCFramer.encode(JSONRPCResponse(id: request.id, result: NewSessionResponse(sessionId: "session-1"))))
        #expect(try await task.value.sessionId == "session-1")
    }

    @Test
    func serverPermissionRequestGetsTypedEventAndResponse() async throws {
        let transport = InMemoryTransport()
        let client = HermesClient(transport: transport)

        var iterator = client.notifications.makeAsyncIterator()
        let nextNotification = Task {
            try await iterator.next()
        }

        let request = RequestPermissionRequest(
            sessionId: "session-1",
            toolCall: ToolCallUpdate(toolCallId: "tool-1", title: "Edit file", kind: .edit, status: .pending),
            options: [
                PermissionOption(optionId: "allow", name: "Allow once", kind: .allowOnce),
                PermissionOption(optionId: "reject", name: "Reject once", kind: .rejectOnce),
            ]
        )
        transport.pushInbound(try JSONRPCFramer.encode(JSONRPCRequest(
            id: .string("permission-1"),
            method: ACPMethod.sessionRequestPermission,
            params: request
        )))

        guard case let .permissionRequest(event)? = try await nextNotification.value else {
            Issue.record("Expected typed permission request event")
            return
        }

        #expect(event.id == .string("permission-1"))
        #expect(event.request == request)

        await event.respond(.selected(SelectedPermissionOutcome(optionId: "allow")))

        let sent = try await waitForSentData(transport, count: 1)
        let response = try decoder.decode(JSONRPCInboundMessage.self, from: sent[0].dropLastNewline())
        #expect(response.id == .string("permission-1"))
        guard case let .object(result)? = response.result,
              case let .object(outcome)? = result["outcome"] else {
            Issue.record("Expected permission response result")
            return
        }
        #expect(outcome["outcome"] == .string("selected"))
        #expect(outcome["optionId"] == .string("allow"))
    }

    @Test
    func permissionResponseWriteFailureUsesClientRequestErrorEvent() async throws {
        let transport = FailingSendTransport()
        let client = HermesClient(transport: transport)

        var iterator = client.notifications.makeAsyncIterator()

        let request = RequestPermissionRequest(
            sessionId: "session-1",
            toolCall: ToolCallUpdate(toolCallId: "tool-1", title: "Edit file"),
            options: [PermissionOption(optionId: "allow", name: "Allow once", kind: .allowOnce)]
        )
        transport.pushInbound(try JSONRPCFramer.encode(JSONRPCRequest(
            id: .string("permission-1"),
            method: ACPMethod.sessionRequestPermission,
            params: request
        )))

        guard case let .permissionRequest(event)? = try await iterator.next() else {
            Issue.record("Expected typed permission request event")
            return
        }

        await event.respond(.cancelled)

        #expect(try await iterator.next() == .clientRequestError(
            id: .string("permission-1"),
            method: ACPMethod.sessionRequestPermission,
            message: TransportError.stdinClosed.localizedDescription
        ))
    }

    @Test
    func malformedJSONFrameDoesNotStopReadLoop() async throws {
        let transport = InMemoryTransport()
        let client = HermesClient(transport: transport)

        var iterator = client.notifications.makeAsyncIterator()
        let nextNotification = Task {
            try await iterator.next()
        }

        transport.pushInbound(Data("{not json}\n".utf8))
        let notification = SessionNotification(
            sessionId: "session-1",
            update: .agentThoughtChunk(Content(content: .text("thinking")))
        )
        transport.pushInbound(try JSONRPCFramer.encode(JSONRPCNotification(method: ACPMethod.sessionUpdate, params: notification)))

        let received = try await nextNotification.value
        #expect(received == .sessionUpdate(notification))
    }

    @Test
    func eofFailsPendingRequests() async throws {
        let transport = InMemoryTransport()
        let client = HermesClient(transport: transport)

        let task = Task {
            try await client.newSession(cwd: "/tmp")
        }

        _ = try await waitForSentData(transport, count: 1)
        transport.finishInbound()

        await #expect(throws: HermesClientError.transportClosed) {
            try await task.value
        }
    }

    @Test
    func closeFinishesNotificationsWithoutError() async throws {
        let transport = InMemoryTransport()
        let client = HermesClient(transport: transport)

        var iterator = client.notifications.makeAsyncIterator()
        await client.close()

        let notification = try await iterator.next()
        #expect(notification == nil)
    }

    @Test
    func cancelDispatchesNotification() async throws {
        let transport = InMemoryTransport()
        let client = HermesClient(transport: transport)

        try await client.cancel(sessionId: "session-1")

        let sent = try await waitForSentData(transport, count: 1)
        let notification = try decoder.decode(JSONRPCInboundMessage.self, from: sent[0].dropLastNewline())
        #expect(notification.id == nil)
        #expect(notification.method == ACPMethod.sessionCancel)
        guard case let .object(params)? = notification.params else {
            Issue.record("Expected cancel params")
            return
        }
        #expect(params["sessionId"] == .string("session-1"))
    }

    private func waitForSentData(_ transport: InMemoryTransport, count: Int) async throws -> [Data] {
        for _ in 0..<100 {
            let data = await transport.sentData()
            if data.count >= count {
                return data
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for \(count) sent frames")
        return await transport.sentData()
    }

    private func decodeRequest(_ frame: Data) throws -> JSONRPCRequest<JSONValue> {
        try decoder.decode(JSONRPCRequest<JSONValue>.self, from: frame.dropLastNewline())
    }
}

private extension Data {
    func dropLastNewline() -> Data {
        guard last == 0x0A else {
            return self
        }
        return Data(dropLast())
    }
}

private actor FailingSendTransport: Transport {
    nonisolated let inbound: AsyncThrowingStream<Data, Error>
    private nonisolated let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init() {
        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        self.inbound = AsyncThrowingStream { continuation in
            captured = continuation
        }
        self.continuation = captured!
    }

    func send(_ data: Data) async throws {
        throw TransportError.stdinClosed
    }

    nonisolated func pushInbound(_ data: Data) {
        continuation.yield(data)
    }

    func close() async {
        continuation.finish()
    }
}

import Foundation
import Testing
@testable import HermesKit

@Suite
struct ACPSchemaTests {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test
    func initializeRequestRoundTripsWithCurrentFieldNames() throws {
        let request = InitializeRequest(
            protocolVersion: 1,
            clientCapabilities: ClientCapabilities(),
            clientInfo: Implementation(name: "Talaria", version: "1.0")
        )

        let object = try jsonObject(request)
        #expect(object["protocolVersion"] == .number(1))
        #expect(object["clientCapabilities"] != nil)
        #expect(object["clientInfo"] != nil)
        #expect(object["capabilities"] == nil)

        let decoded = try decoder.decode(InitializeRequest.self, from: encoder.encode(request))
        #expect(decoded == request)
    }

    @Test
    func initializeResponseRoundTripsWithAgentCapabilities() throws {
        let response = InitializeResponse(
            protocolVersion: 1,
            agentCapabilities: AgentCapabilities(loadSession: true),
            agentInfo: Implementation(name: "Hermes", version: "0.1"),
            authMethods: []
        )

        let object = try jsonObject(response)
        #expect(object["protocolVersion"] == .number(1))
        #expect(object["agentCapabilities"] != nil)
        #expect(object["agentInfo"] != nil)

        let decoded = try decoder.decode(InitializeResponse.self, from: encoder.encode(response))
        #expect(decoded == response)
    }

    @Test
    func sessionNewResponseRoundTrips() throws {
        let response = NewSessionResponse(sessionId: "session-1")

        let object = try jsonObject(response)
        #expect(object["sessionId"] == .string("session-1"))

        let decoded = try decoder.decode(NewSessionResponse.self, from: encoder.encode(response))
        #expect(decoded == response)
    }

    @Test
    func sessionNewRequestEncodesRemoteMcpServerTypes() throws {
        let request = NewSessionRequest(
            cwd: "/tmp/project",
            mcpServers: [
                .sse(McpServerSse(name: "events", url: "https://example.com/sse")),
                .http(McpServerHttp(name: "api", url: "https://example.com/mcp", headers: [HttpHeader(name: "Authorization", value: "Bearer token")])),
            ]
        )

        let object = try jsonObject(request)
        guard case let .array(servers)? = object["mcpServers"],
              case let .object(sse)? = servers.first,
              case let .object(http)? = servers.dropFirst().first else {
            Issue.record("Expected MCP server array")
            return
        }

        #expect(sse["type"] == .string("sse"))
        #expect(sse["name"] == .string("events"))
        #expect(sse["url"] == .string("https://example.com/sse"))
        #expect(http["type"] == .string("http"))
        #expect(http["name"] == .string("api"))
        #expect(http["url"] == .string("https://example.com/mcp"))

        let decoded = try decoder.decode(NewSessionRequest.self, from: encoder.encode(request))
        #expect(decoded == request)
    }

    @Test
    func promptRequestUsesContentBlocks() throws {
        let request = PromptRequest(sessionId: "session-1", prompt: [.text("hello")])

        let object = try jsonObject(request)
        #expect(object["sessionId"] == .string("session-1"))
        guard case let .array(prompt)? = object["prompt"],
              case let .object(textBlock) = prompt.first else {
            Issue.record("Expected prompt content block")
            return
        }
        #expect(textBlock["type"] == .string("text"))
        #expect(textBlock["text"] == .string("hello"))

        let decoded = try decoder.decode(PromptRequest.self, from: encoder.encode(request))
        #expect(decoded == request)
    }

    @Test
    func promptResponseRoundTrips() throws {
        let response = PromptResponse(stopReason: .endTurn)

        let object = try jsonObject(response)
        #expect(object["stopReason"] == .string("end_turn"))

        let decoded = try decoder.decode(PromptResponse.self, from: encoder.encode(response))
        #expect(decoded == response)
    }

    @Test
    func cancelNotificationShapeRoundTrips() throws {
        let notification = JSONRPCNotification(method: ACPMethod.sessionCancel, params: CancelNotification(sessionId: "session-1"))

        let object = try jsonObject(notification)
        #expect(object["method"] == .string("session/cancel"))
        #expect(object["id"] == nil)
        guard case let .object(params)? = object["params"] else {
            Issue.record("Expected cancel params")
            return
        }
        #expect(params["sessionId"] == .string("session-1"))
    }

    @Test
    func representativeSessionUpdatesRoundTrip() throws {
        let updates: [SessionUpdate] = [
            .userMessageChunk(Content(content: .text("user"))),
            .agentMessageChunk(Content(content: .text("agent"))),
            .agentThoughtChunk(Content(content: .text("thought"))),
            .toolCall(ToolCall(toolCallId: "tool-1", title: "Read file", kind: .read, status: .pending)),
            .toolCallUpdate(ToolCallUpdate(toolCallId: "tool-1", title: "Read file", status: .completed)),
        ]

        for update in updates {
            let decoded = try decoder.decode(SessionUpdate.self, from: encoder.encode(update))
            #expect(decoded == update)
        }
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: JSONValue] {
        let data = try encoder.encode(value)
        guard case let .object(object) = try decoder.decode(JSONValue.self, from: data) else {
            Issue.record("Expected JSON object")
            return [:]
        }
        return object
    }
}

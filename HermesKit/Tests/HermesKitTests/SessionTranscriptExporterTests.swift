import Foundation
import Testing
@testable import HermesKit

@Suite
struct SessionTranscriptExporterTests {
    /// Decodes a single JSONL line back into a `DashboardMessage` for round-trip
    /// assertions.
    private func decode(_ line: String) throws -> DashboardMessage {
        try JSONDecoder().decode(DashboardMessage.self, from: Data(line.utf8))
    }

    @Test
    func emptyInputYieldsEmptyString() {
        #expect(SessionTranscriptExporter.jsonl(from: []) == "")
    }

    @Test
    func singleMessageProducesOneLine() throws {
        let message = DashboardMessage(
            role: "user",
            content: .string("hello"),
            toolCalls: nil,
            toolCallId: nil,
            toolName: nil,
            reasoning: nil,
            reasoningContent: nil
        )

        let jsonl = SessionTranscriptExporter.jsonl(from: [message])

        // One line, no trailing newline.
        #expect(!jsonl.contains("\n"))
        #expect(try decode(jsonl) == message)
    }

    @Test
    func multipleMessagesPreserveOrderOnePerLine() throws {
        let messages = (0..<3).map { index in
            DashboardMessage(
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: .string("message \(index)"),
                toolCalls: nil,
                toolCallId: nil,
                toolName: nil,
                reasoning: nil,
                reasoningContent: nil
            )
        }

        let lines = SessionTranscriptExporter.jsonl(from: messages).split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines.count == messages.count)
        for (line, message) in zip(lines, messages) {
            #expect(try decode(String(line)) == message)
        }
    }

    @Test
    func nestedArrayAndObjectContentRoundTrips() throws {
        let message = DashboardMessage(
            role: "assistant",
            content: .array([
                .object([
                    "type": .string("text"),
                    "text": .string("see file.swift"),
                ]),
                .object([
                    "type": .string("tool_use"),
                    "nested": .array([.number(1), .bool(true), .null]),
                ]),
            ]),
            toolCalls: .object(["id": .string("call_1")]),
            toolCallId: "call_1",
            toolName: "read",
            reasoning: "because",
            reasoningContent: nil
        )

        let jsonl = SessionTranscriptExporter.jsonl(from: [message])

        #expect(!jsonl.contains("\n"))
        #expect(try decode(jsonl) == message)
    }

    @Test
    func keysAreSortedForStableOutput() {
        let message = DashboardMessage(
            role: "tool",
            content: .string("ok"),
            toolCalls: nil,
            toolCallId: "abc",
            toolName: "read",
            reasoning: nil,
            reasoningContent: nil
        )

        let jsonl = SessionTranscriptExporter.jsonl(from: [message])

        // `.sortedKeys` orders top-level keys alphabetically: content, role,
        // tool_call_id, tool_name.
        let contentIndex = jsonl.range(of: "\"content\"")
        let roleIndex = jsonl.range(of: "\"role\"")
        let toolNameIndex = jsonl.range(of: "\"tool_name\"")
        #expect(contentIndex != nil && roleIndex != nil && toolNameIndex != nil)
        #expect(contentIndex!.lowerBound < roleIndex!.lowerBound)
        #expect(roleIndex!.lowerBound < toolNameIndex!.lowerBound)
    }
}

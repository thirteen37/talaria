import Foundation
import HermesKit
import Testing
@testable import Talaria

@Suite
struct SessionHistoryMapperTests {
    @Test
    func mapsDashboardMessagesToTranscript() throws {
        let payload = try JSONDecoder().decode(
            DashboardSessionMessagesResponse.self,
            from: Data(
                """
                {
                  "session_id": "external-1",
                  "messages": [
                    { "role": "user", "content": "Show me the file" },
                    {
                      "role": "assistant",
                      "content": [
                        { "type": "text", "text": "I will inspect it." },
                        { "type": "text", "text": "Then summarize it." }
                      ],
                      "reasoning_content": "Need to read before answering.",
                      "tool_calls": [
                        {
                          "id": "call_read",
                          "type": "function",
                          "function": { "name": "read_file", "arguments": "{\\"path\\":\\"README.md\\"}" }
                        }
                      ]
                    },
                    {
                      "role": "tool",
                      "content": "README contents",
                      "tool_call_id": "call_read",
                      "tool_name": "read_file"
                    }
                  ]
                }
                """.utf8
            )
        )

        let transcript = SessionHistoryMapper.messages(from: payload.messages)

        #expect(transcript.map(\.kind) == [
            ChatTranscriptMessage.Kind.user,
            ChatTranscriptMessage.Kind.thought,
            ChatTranscriptMessage.Kind.agent,
            ChatTranscriptMessage.Kind.tool
        ])
        #expect(transcript[0].text == "Show me the file")
        #expect(transcript[1].text == "Need to read before answering.")
        #expect(transcript[2].text == "I will inspect it.\nThen summarize it.")
        #expect(transcript[3].toolCallId == "call_read")
        #expect(transcript[3].toolTitle == "read_file")
        #expect(transcript[3].toolStatus == ToolCallStatus.completed)
        #expect(transcript[3].text == "read_file (completed)")
        guard case let .content(content)? = transcript[3].toolContent.first else {
            Issue.record("Expected tool result content")
            return
        }
        #expect(content.content.plainText == "README contents")
    }
}

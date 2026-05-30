import Foundation
import HermesKit

enum SessionHistoryMapper {
    static func messages(from dashboardMessages: [DashboardMessage]) -> [ChatTranscriptMessage] {
        var transcript: [ChatTranscriptMessage] = []
        var toolIndexes: [ToolCallId: Int] = [:]

        for message in dashboardMessages {
            switch message.role {
            case "user":
                appendText(message.plainText, kind: .user, to: &transcript)
            case "assistant":
                appendText(message.reasoningContent ?? message.reasoning, kind: .thought, to: &transcript)
                appendText(message.plainText, kind: .agent, to: &transcript)
                for toolCall in toolCalls(from: message.toolCalls) {
                    let displayTitle = toolCall.name ?? toolCall.id
                    let row = ChatTranscriptMessage(
                        kind: .tool,
                        text: toolText(title: displayTitle, status: .pending),
                        toolCallId: toolCall.id,
                        toolTitle: displayTitle,
                        toolStatus: .pending
                    )
                    transcript.append(row)
                    toolIndexes[toolCall.id] = transcript.count - 1
                }
            case "tool":
                let toolCallId = message.toolCallId ?? "tool-\(transcript.count)"
                let displayTitle = message.toolName ?? toolCallId
                let content = toolContent(from: message.plainText)
                if let index = toolIndexes[toolCallId] {
                    transcript[index].text = toolText(title: transcript[index].toolTitle ?? displayTitle, status: .completed)
                    transcript[index].toolTitle = transcript[index].toolTitle ?? displayTitle
                    transcript[index].toolStatus = .completed
                    transcript[index].toolContent = content
                } else {
                    let row = ChatTranscriptMessage(
                        kind: .tool,
                        text: toolText(title: displayTitle, status: .completed),
                        toolCallId: toolCallId,
                        toolTitle: displayTitle,
                        toolStatus: .completed,
                        toolContent: content
                    )
                    transcript.append(row)
                    toolIndexes[toolCallId] = transcript.count - 1
                }
            default:
                appendText(message.plainText, kind: .event, to: &transcript)
            }
        }

        return transcript
    }

    private static func appendText(
        _ text: String?,
        kind: ChatTranscriptMessage.Kind,
        to transcript: inout [ChatTranscriptMessage]
    ) {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return
        }
        transcript.append(ChatTranscriptMessage(kind: kind, text: text))
    }

    private static func toolText(title: String, status: ToolCallStatus) -> String {
        "\(title) (\(status.rawValue))"
    }

    private static func toolContent(from text: String?) -> [ToolCallContent] {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return []
        }
        return [.content(Content(content: .text(text)))]
    }

    private static func toolCalls(from value: JSONValue?) -> [HistoryToolCall] {
        guard let value = normalizedJSON(value) else {
            return []
        }
        switch value {
        case let .array(values):
            return values.enumerated().compactMap { index, value in
                toolCall(from: value, index: index)
            }
        case .object:
            return toolCall(from: value, index: 0).map { [$0] } ?? []
        default:
            return []
        }
    }

    private static func normalizedJSON(_ value: JSONValue?) -> JSONValue? {
        guard let value else { return nil }
        if case let .string(text) = value,
           let data = text.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return decoded
        }
        return value
    }

    private static func toolCall(from value: JSONValue, index: Int) -> HistoryToolCall? {
        guard case let .object(object) = value else {
            return nil
        }
        let id = stringValue(object["id"])
            ?? stringValue(object["tool_call_id"])
            ?? stringValue(object["call_id"])
            ?? "tool-\(index)"
        let name = stringValue(object["name"])
            ?? stringValue(object["tool_name"])
            ?? functionName(from: object["function"])
        return HistoryToolCall(id: id, name: name)
    }

    private static func functionName(from value: JSONValue?) -> String? {
        guard case let .object(function)? = value else {
            return nil
        }
        return stringValue(function["name"])
    }

    private static func stringValue(_ value: JSONValue?) -> String? {
        guard case let .string(text)? = value, !text.isEmpty else {
            return nil
        }
        return text
    }
}

private struct HistoryToolCall {
    var id: ToolCallId
    var name: String?
}

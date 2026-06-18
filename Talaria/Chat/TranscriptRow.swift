import SwiftUI

struct TranscriptRow: View {
    let message: ChatTranscriptMessage
    let isLast: Bool
    /// True when the turn is in flight and this is the last block — i.e. the row
    /// whose text is actively growing. Forwarded so code blocks defer syntax
    /// highlighting until streaming stops.
    let isStreaming: Bool
    /// Non-nil only for user bubbles that can be undone; forwarded to `ChatBubble`.
    var onUndo: (() -> Void)?

    var body: some View {
        switch message.kind {
        case .tool:
            ToolCard(message: message, isStreaming: isStreaming)
        case .thought:
            ReasoningPanel(message: message, isActive: isLast, isStreaming: isStreaming)
        default:
            ChatBubble(message: message, onUndo: onUndo, isStreaming: isStreaming)
        }
    }
}

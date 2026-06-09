import SwiftUI

struct TranscriptRow: View {
    let message: ChatTranscriptMessage
    let isLast: Bool
    /// Non-nil only for user bubbles that can be undone; forwarded to `ChatBubble`.
    var onUndo: (() -> Void)?

    var body: some View {
        switch message.kind {
        case .tool:
            ToolCard(message: message)
        case .thought:
            ReasoningPanel(message: message, isActive: isLast)
        default:
            ChatBubble(message: message, onUndo: onUndo)
        }
    }
}

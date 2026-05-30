import SwiftUI

struct TranscriptRow: View {
    let message: ChatTranscriptMessage
    let isLast: Bool

    var body: some View {
        switch message.kind {
        case .tool:
            ToolCard(message: message)
        case .thought:
            ReasoningPanel(message: message, isActive: isLast)
        default:
            ChatBubble(message: message)
        }
    }
}

import SwiftUI

struct TranscriptRow: View {
    let message: ChatTranscriptMessage

    var body: some View {
        switch message.kind {
        case .tool:
            ToolCard(message: message)
        case .thought:
            ReasoningPanel(message: message)
        default:
            ChatBubble(message: message)
        }
    }
}

import SwiftUI

struct ChatBubble: View {
    let message: ChatTranscriptMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.kind.systemImage)
                .foregroundStyle(message.kind.tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 6) {
                Text(message.kind.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                MarkdownText(text: message.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(message.kind.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

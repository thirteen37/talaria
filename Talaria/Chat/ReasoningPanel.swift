import SwiftUI

struct ReasoningPanel: View {
    let message: ChatTranscriptMessage
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            MarkdownText(text: message.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            Label(message.kind.title, systemImage: message.kind.systemImage)
                .font(.caption)
                .foregroundStyle(message.kind.tint)
        }
        .padding(10)
        .background(message.kind.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

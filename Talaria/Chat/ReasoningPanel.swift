import SwiftUI

struct ReasoningPanel: View {
    let message: ChatTranscriptMessage
    /// True while this thought is the last (streaming) block. When it flips to
    /// false — i.e. the next block starts — the panel auto-collapses once.
    let isActive: Bool
    @State private var isExpanded: Bool

    init(message: ChatTranscriptMessage, isActive: Bool) {
        self.message = message
        self.isActive = isActive
        _isExpanded = State(initialValue: isActive)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            MarkdownText(text: message.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Label(message.kind.title, systemImage: message.kind.systemImage)
                    .font(.caption)
                    .foregroundStyle(message.kind.tint)
                    .layoutPriority(1)

                if !isExpanded, !previewText.isEmpty {
                    Text(previewText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(message.kind.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        // Drive automatic collapse only on the active -> inactive transition, so a
        // manually re-opened thought stays open for the life of the view. (Rows
        // live in a LazyVStack and re-seed `isExpanded` from `isActive` when
        // recycled off-screen, so a finished thought re-collapses to the default
        // after scrolling far away and back — acceptable since that's the
        // intended quiet default, not lost content.)
        .onChange(of: isActive) { _, nowActive in
            if !nowActive {
                isExpanded = false
            }
        }
    }

    /// A short, single-line peek of the thought shown while collapsed.
    private var previewText: String {
        message.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
    }
}

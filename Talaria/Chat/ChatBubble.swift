import SwiftUI

struct ChatBubble: View {
    let message: ChatTranscriptMessage
    /// Non-nil only for user bubbles that can be rewound to; shows an Undo action.
    var onUndo: (() -> Void)?

    #if os(macOS)
    @State private var isHovering = false
    #endif

    var body: some View {
        bubble
        #if os(macOS)
            // Hover-reveal a trailing action row, mirroring `SessionsBrowser`.
            .overlay(alignment: .topTrailing) {
                actions
                    .padding(6)
                    .opacity(isHovering ? 1 : 0)
            }
            .onHover { isHovering = $0 }
        #else
            // Long-press reveals the same actions on iOS.
            .contextMenu {
                Button {
                    Pasteboard.copy(message.text)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                if let onUndo {
                    Button(action: onUndo) {
                        Label("Undo back to here", systemImage: "arrow.uturn.backward")
                    }
                }
            }
        #endif
    }

    private var bubble: some View {
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

    #if os(macOS)
    private var actions: some View {
        HStack(spacing: 2) {
            Button {
                Pasteboard.copy(message.text)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy message")
            .accessibilityLabel("Copy message")

            if let onUndo {
                Button(action: onUndo) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("Undo back to here")
                .accessibilityLabel("Undo back to here")
            }
        }
        .buttonStyle(.borderless)
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    #endif
}

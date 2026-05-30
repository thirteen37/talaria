import HermesKit
import SwiftUI

struct ToolCard: View {
    let message: ChatTranscriptMessage
    @State private var isExpanded: Bool

    init(message: ChatTranscriptMessage) {
        self.message = message
        _isExpanded = State(initialValue: message.toolStatus.isActive)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(message.toolContent.enumerated()), id: \.offset) { _, content in
                    ToolContentView(content: content)
                }

                if message.toolContent.isEmpty, !message.text.isEmpty {
                    MarkdownText(text: message.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: message.kind.systemImage)
                    .foregroundStyle(message.kind.tint)
                    .frame(width: 20)

                Text(message.toolTitle ?? message.text)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let status = message.toolStatus {
                    ToolStatusPill(status: status)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(message.kind.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        // Collapse only on the transition into a terminal status, so a manually
        // re-expanded completed tool stays open for the life of the view. (As in
        // ReasoningPanel, a LazyVStack recycle re-seeds `isExpanded` from the
        // status, so a finished tool re-collapses to the default after scrolling
        // far off-screen and back.)
        .onChange(of: message.toolStatus) { _, status in
            if !status.isActive {
                isExpanded = false
            }
        }
    }
}

private struct ToolContentView: View {
    let content: ToolCallContent

    var body: some View {
        switch content {
        case let .content(content):
            if let text = content.content.plainText {
                MarkdownText(text: text)
                    .font(.callout)
            }
        case let .diff(diff):
            DiffView(diff: diff)
        case let .terminal(terminal):
            Label(terminal.terminalId, systemImage: "terminal")
                .font(.callout)
                .foregroundStyle(.secondary)
        case let .unknown(value):
            Text(String(describing: value))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct ToolStatusPill: View {
    let status: ToolCallStatus

    var body: some View {
        Text(statusTitle)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(statusColor.opacity(0.12), in: Capsule())
    }

    private var statusTitle: String {
        switch status {
        case .pending: "Pending"
        case .inProgress: "Running"
        case .completed: "Done"
        case .failed: "Error"
        }
    }

    private var statusColor: Color {
        switch status {
        case .pending: .secondary
        case .inProgress: .blue
        case .completed: .green
        case .failed: .red
        }
    }
}

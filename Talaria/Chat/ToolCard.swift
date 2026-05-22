import HermesKit
import SwiftUI

struct ToolCard: View {
    let message: ChatTranscriptMessage
    @State private var isExpanded = true

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
        .padding(10)
        .background(message.kind.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

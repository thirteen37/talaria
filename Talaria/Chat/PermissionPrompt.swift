import HermesKit
import SwiftUI

struct PermissionPrompt: View {
    let state: PermissionPromptState
    let select: (PermissionOption) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Permission Required")
                        .font(.headline)
                    Text(state.request.toolCall.title ?? state.request.toolCall.toolCallId)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }

            if let content = state.request.toolCall.content {
                ForEach(Array(content.enumerated()), id: \.offset) { _, item in
                    PermissionToolContent(content: item)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(state.request.options, id: \.optionId) { option in
                    Button {
                        select(option)
                    } label: {
                        Label(option.name, systemImage: iconName(for: option.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tint(for: option.kind))
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 560, maxWidth: 680)
    }

    private func iconName(for kind: PermissionOptionKind) -> String {
        switch kind {
        case .allowOnce, .allowAlways: "checkmark.circle"
        case .rejectOnce, .rejectAlways: "xmark.circle"
        }
    }

    private func tint(for kind: PermissionOptionKind) -> Color {
        switch kind {
        case .allowOnce, .allowAlways: .green
        case .rejectOnce, .rejectAlways: .red
        }
    }
}

private struct PermissionToolContent: View {
    let content: ToolCallContent

    var body: some View {
        switch content {
        case let .diff(diff):
            DiffView(diff: diff)
        case let .content(content):
            if let text = content.content.plainText {
                MarkdownText(text: text)
                    .font(.callout)
            }
        case let .terminal(terminal):
            Label(terminal.terminalId, systemImage: "terminal")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .unknown:
            EmptyView()
        }
    }
}

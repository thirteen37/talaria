import HermesKit
import SwiftUI

struct PermissionPrompt: View {
    let state: PermissionPromptState
    let select: (PermissionOption) -> Void
    let cancel: () -> Void

    var body: some View {
        // macOS: fixed comfortably-wide frame. iOS: scrollable, fills the sheet
        // width so a tall payload stays reachable on a phone-sized screen.
        promptBody.permissionPromptLayout()
    }

    private var promptBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: headerIcon)
                    .font(.title3)
                    .foregroundStyle(headerIconColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    if let headerTitle {
                        Text(headerTitle)
                            .font(.headline)
                    }
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

            // `.secret`/`.sudo` can't capture a typed value yet (v1 limitation —
            // see `emitTextSecret`), so its only option is a Cancel placeholder
            // that does exactly what the bottom Cancel does. Suppress it rather
            // than show two cancel affordances; the bottom Cancel unblocks the
            // agent with an empty value.
            if state.kind != .secret {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(state.request.options, id: \.optionId) { option in
                        optionButton(option)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    @ViewBuilder
    private func optionButton(_ option: PermissionOption) -> some View {
        // A clarify question's choices are answers, not allow/deny — render them
        // as neutral bordered buttons with no allow/deny icon.
        if state.kind == .question {
            Button {
                select(option)
            } label: {
                Text(option.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
        } else {
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

    private var headerTitle: String? {
        switch state.kind {
        case .permission: "Permission Required"
        case .question: nil   // the question text alone carries the meaning
        case .secret: nil
        }
    }

    private var headerIcon: String {
        switch state.kind {
        case .permission: "hand.raised.fill"
        case .question: "questionmark.circle"
        case .secret: "lock.fill"
        }
    }

    private var headerIconColor: Color {
        switch state.kind {
        case .permission: .orange
        case .question: .accentColor
        case .secret: .secondary
        }
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
                MarkdownText(text: text, style: .plain)
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

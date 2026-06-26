import HermesKit
import SwiftUI

struct PermissionPrompt: View {
    let state: PermissionPromptState
    /// Focus binding owned by `ChatView` so the card can take focus when it first
    /// appears (focus ring + steals key input from the disabled composer). Optional
    /// and defaulted so non-focusing call sites (e.g. `PromptShotRenderer`) keep
    /// compiling.
    var isFocused: FocusState<Bool>.Binding? = nil
    let select: (PermissionOption) -> Void
    let cancel: () -> Void

    /// Number of options that get a `⌥N` key-hint badge (and a matching shortcut in
    /// `ChatView`'s persistent layer). Realistically ≤4; capped at 9 because the
    /// shortcut keys are the single digits 1–9.
    static let maxShortcutOptions = 9

    var body: some View {
        // An inline transcript card (full width, kind-tinted border) rather than a
        // modal sheet — it scrolls with the message list so history stays reachable
        // while the prompt is pending.
        if let isFocused {
            card
                .focusable()
                .focused(isFocused)
        } else {
            card
        }
    }

    private var card: some View {
        promptBody
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.background.secondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(headerIconColor.opacity(0.55), lineWidth: 1)
            )
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
                    ForEach(Array(state.request.options.enumerated()), id: \.element.optionId) { index, option in
                        optionButton(option, index: index)
                    }
                }
            }

            HStack {
                Spacer()
                // No `.keyboardShortcut(.cancelAction)` here — Esc is owned by
                // `ChatView`'s persistent shortcut layer, which survives this card
                // scrolling out of the `LazyVStack`. A second `.cancelAction` would
                // conflict with it.
                Button("Cancel", role: .cancel, action: cancel)
            }
        }
    }

    @ViewBuilder
    private func optionButton(_ option: PermissionOption, index: Int) -> some View {
        // A clarify question's choices are answers, not allow/deny — render them
        // as neutral bordered buttons with no allow/deny icon.
        if state.kind == .question {
            Button {
                select(option)
            } label: {
                optionLabel(Text(option.name), index: index)
            }
            .buttonStyle(.bordered)
        } else {
            Button {
                select(option)
            } label: {
                optionLabel(Label(option.name, systemImage: iconName(for: option.kind)), index: index)
            }
            .buttonStyle(.borderedProminent)
            .tint(tint(for: option.kind))
        }
    }

    /// Wraps an option's label with its `⌥N` key-hint badge on the trailing edge.
    /// Only the first `maxShortcutOptions` options are badged (matching the
    /// shortcuts wired up in `ChatView`), and only where a hardware keyboard is
    /// guaranteed — otherwise the badge would advertise an unreachable shortcut.
    @ViewBuilder
    private func optionLabel(_ label: some View, index: Int) -> some View {
        HStack(spacing: 8) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
            if Platform.showsKeyboardShortcutHints, index < Self.maxShortcutOptions {
                Text("⌥\(index + 1)")
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.thinMaterial, in: Capsule())
            }
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

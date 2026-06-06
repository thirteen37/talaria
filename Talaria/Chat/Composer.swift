import HermesKit
import SwiftUI

struct Composer: View {
    @Binding var prompt: String
    var isSending: Bool
    var isBlocked: Bool
    var availableCommands: [AvailableCommand]
    var send: () -> Void
    var cancel: () -> Void
    @State private var isSlashMenuDismissed = false
    @State private var slashMenuHeight: CGFloat = 0

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matchingCommands: [AvailableCommand] {
        guard prompt.hasPrefix("/") else {
            return []
        }

        let query = String(prompt.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            return availableCommands
        }
        return availableCommands.filter { $0.name.lowercased().contains(query) }
    }

    private var visibleCommands: [AvailableCommand] {
        isSlashMenuDismissed ? [] : matchingCommands
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField(isBlocked ? "Waiting for permission" : "Message Hermes", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .disabled(isBlocked)
                .onChange(of: prompt) { _, newValue in
                    if !newValue.hasPrefix("/") {
                        isSlashMenuDismissed = false
                    }
                }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) {
                        return .ignored
                    }
                    if let command = visibleCommands.first {
                        accept(command)
                        return .handled
                    }
                    send()
                    return .handled
                }
                .onKeyPress(.tab, phases: .down) { _ in
                    guard let command = visibleCommands.first else {
                        return .ignored
                    }
                    accept(command)
                    return .handled
                }
                .onKeyPress(.escape, phases: .down) { _ in
                    guard !visibleCommands.isEmpty else {
                        return .ignored
                    }
                    isSlashMenuDismissed = true
                    return .handled
                }

            if isSending {
                Button(action: cancel) {
                    Image(systemName: "stop.fill")
                }
                .help("Cancel")
                .accessibilityLabel("Cancel")
            } else {
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                }
                .help("Send")
                .accessibilityLabel("Send")
                .disabled(trimmedPrompt.isEmpty || isBlocked)
            }
        }
        // Float the slash-command menu above the input row as an overlay so it no
        // longer consumes layout height — the composer's measured height stays
        // constant whether or not the menu shows, so the status bar / transcript
        // above it don't get pushed up. The overlay anchors to the input `HStack`
        // (before the outer `.padding`) so its container top edge is the text box's
        // top edge, then we lift the menu by its own measured height via `.offset`
        // so its bottom edge lands exactly on the top of the text box. (An
        // `.alignmentGuide(.top) { $0[.bottom] }` is unreliable inside `.overlay` —
        // it left the menu sitting on top of the text field — so we measure and
        // offset instead. The opacity gate hides the menu for the single layout
        // pass before its height is known, avoiding a flash at the un-offset spot.)
        .overlay(alignment: .topLeading) {
            if !visibleCommands.isEmpty, !isBlocked {
                SlashMenu(commands: visibleCommands) { command in
                    accept(command)
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: SlashMenuHeightKey.self, value: proxy.size.height)
                    }
                )
                .onPreferenceChange(SlashMenuHeightKey.self) { height in
                    if abs(height - slashMenuHeight) > 0.5 {
                        slashMenuHeight = height
                    }
                }
                .offset(y: -slashMenuHeight)
                .opacity(slashMenuHeight > 0 ? 1 : 0)
            }
        }
        .padding(12)
    }

    private func accept(_ command: AvailableCommand) {
        prompt = "/\(command.name) "
        isSlashMenuDismissed = true
    }
}

private struct SlashMenuHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

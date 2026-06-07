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
    @State private var selectedCommandIndex = 0

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matchingCommands: [AvailableCommand] {
        guard prompt.hasPrefix("/") else {
            return []
        }

        let query = String(prompt.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rankedSlashCommands(availableCommands, matching: query)
    }

    private var visibleCommands: [AvailableCommand] {
        isSlashMenuDismissed ? [] : matchingCommands
    }

    /// The currently highlighted command, falling back to the first row if the
    /// tracked index has drifted out of bounds (defensive; the index is reset to
    /// 0 on every re-filter, which is always valid for a non-empty list).
    private var selectedCommand: AvailableCommand? {
        let commands = visibleCommands
        guard !commands.isEmpty else { return nil }
        return commands.indices.contains(selectedCommandIndex)
            ? commands[selectedCommandIndex]
            : commands.first
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
                    // Each keystroke re-filters the list; reset the highlight to
                    // the top (index 0 is always valid for a non-empty list).
                    selectedCommandIndex = 0
                }
                .onKeyPress(.upArrow, phases: .down) { _ in
                    let count = visibleCommands.count
                    guard count > 0 else { return .ignored }
                    selectedCommandIndex = (selectedCommandIndex - 1 + count) % count
                    return .handled
                }
                .onKeyPress(.downArrow, phases: .down) { _ in
                    let count = visibleCommands.count
                    guard count > 0 else { return .ignored }
                    selectedCommandIndex = (selectedCommandIndex + 1) % count
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) {
                        return .ignored
                    }
                    if let command = selectedCommand {
                        accept(command)
                        return .handled
                    }
                    send()
                    return .handled
                }
                .onKeyPress(.tab, phases: .down) { _ in
                    guard let command = selectedCommand else {
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
                SlashMenu(commands: visibleCommands, selectedIndex: selectedCommandIndex) { command in
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

/// Match quality of `query` against a command `name`, lower = better.
/// Returns nil when the name does not contain the query at all.
/// Both arguments are expected lowercased.
func slashCommandMatchTier(name: String, query: String) -> Int? {
    if name == query { return 0 }
    if name.hasPrefix(query) { return 1 }
    guard let range = name.range(of: query) else { return nil }
    let before = name[name.index(before: range.lowerBound)]
    return "-_:./ ".contains(before) ? 2 : 3
}

/// Filter `commands` to those whose name matches `query` (case-insensitive
/// substring) and order them by match quality (exact > prefix > word-boundary
/// > interior). Ties preserve original server order. `query` should already be
/// lowercased and trimmed; an empty query returns `commands` unchanged.
func rankedSlashCommands(_ commands: [AvailableCommand], matching query: String) -> [AvailableCommand] {
    guard !query.isEmpty else { return commands }
    return commands.enumerated()
        .compactMap { index, command -> (tier: Int, index: Int, command: AvailableCommand)? in
            guard let tier = slashCommandMatchTier(name: command.name.lowercased(), query: query)
            else { return nil }
            return (tier, index, command)
        }
        .sorted { $0.tier != $1.tier ? $0.tier < $1.tier : $0.index < $1.index }
        .map(\.command)
}

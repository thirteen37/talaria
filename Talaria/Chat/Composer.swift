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
                .overlay(alignment: .topLeading) {
                    if !visibleCommands.isEmpty, !isBlocked {
                        SlashMenu(commands: visibleCommands) { command in
                            accept(command)
                        }
                        .offset(x: 0, y: -8)
                        .alignmentGuide(.top) { dimensions in dimensions[.bottom] }
                    }
                }
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
            } else {
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                }
                .help("Send")
                .disabled(trimmedPrompt.isEmpty || isBlocked)
            }
        }
        .padding(12)
    }

    private func accept(_ command: AvailableCommand) {
        prompt = "/\(command.name) "
        isSlashMenuDismissed = true
    }
}

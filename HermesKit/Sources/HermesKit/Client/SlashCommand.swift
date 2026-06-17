import Foundation

/// A typed slash command split into its name and argument. Shared by the app's
/// send-path routing (`LocalChatViewModel.sendPrompt`) and ``GatewayChatClient``'s
/// `command.dispatch` fallback so the two never drift on how a command parses —
/// leading-slash strip plus a split on the first whitespace run.
public struct SlashCommand: Equatable, Sendable {
    /// The command name (first token), with any leading `/`(s) removed.
    public let name: String
    /// The trimmed remainder after the first whitespace, or `""` when absent.
    public let arg: String

    public init(parsing text: String) {
        let bare = String(text.drop(while: { $0 == "/" }))
        let trimmed = bare.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let idx = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "\n" }) else {
            self.name = trimmed
            self.arg = ""
            return
        }
        self.name = String(trimmed[..<idx])
        self.arg = String(trimmed[trimmed.index(after: idx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Slash commands Hermes accepts while a turn is in flight — the gateway's
    /// "pending-input set" (`command.dispatch`, `server.py:5931`). These are the
    /// only commands (besides auto-queued plain text) the composer dispatches
    /// over a live turn; everything else is gated until the turn finishes.
    public static let pendingInputCommands: Set<String> = ["retry", "queue", "q", "steer", "plan", "goal", "undo"]

    /// Whether this command may be dispatched mid-turn (see ``pendingInputCommands``).
    /// Compared case-insensitively so `/QUEUE` classifies like `/queue`.
    public var isPendingInput: Bool { Self.pendingInputCommands.contains(name.lowercased()) }
}

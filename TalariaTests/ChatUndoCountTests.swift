import Foundation
import HermesKit
import Testing
@testable import Talaria

@Suite
struct ChatUndoCountTests {
    /// A small interleaved transcript: user / agent / event / user / agent / user.
    private func transcript() -> [ChatTranscriptMessage] {
        [
            ChatTranscriptMessage(kind: .user, text: "first question"),
            ChatTranscriptMessage(kind: .agent, text: "first answer"),
            ChatTranscriptMessage(kind: .event, text: "Renamed session"),
            ChatTranscriptMessage(kind: .user, text: "second question"),
            ChatTranscriptMessage(kind: .agent, text: "second answer"),
            ChatTranscriptMessage(kind: .user, text: "third question"),
        ]
    }

    @Test
    func latestUserBubbleIsOne() {
        let messages = transcript()
        let last = messages[5]   // third (latest) user bubble
        #expect(LocalChatViewModel.undoTurnCount(through: last.id, in: messages) == 1)
    }

    @Test
    func priorUserBubbleIsTwo() {
        let messages = transcript()
        let middle = messages[3]   // second user bubble
        // From the second user bubble forward: it + the third user bubble = 2.
        #expect(LocalChatViewModel.undoTurnCount(through: middle.id, in: messages) == 2)
    }

    @Test
    func firstUserBubbleCountsAllUserTurns() {
        let messages = transcript()
        let first = messages[0]   // first user bubble
        #expect(LocalChatViewModel.undoTurnCount(through: first.id, in: messages) == 3)
    }

    @Test
    func nonUserIdCountsFromItsEnclosingPosition() {
        let messages = transcript()
        // The event bubble (index 2) sits before two later user bubbles.
        let event = messages[2]
        #expect(LocalChatViewModel.undoTurnCount(through: event.id, in: messages) == 2)
    }

    @Test
    func missingIdReturnsZero() {
        let messages = transcript()
        #expect(LocalChatViewModel.undoTurnCount(through: UUID(), in: messages) == 0)
    }

    @Test
    func slashCommandEchoesAreNotCounted() {
        // `sendPrompt` echoes `/help`, `/model`, … as `.user` bubbles, but they
        // run through the harness, not the LLM — so they aren't real turns and
        // must not inflate `/undo <N>`.
        let messages = [
            ChatTranscriptMessage(kind: .user, text: "real question"),
            ChatTranscriptMessage(kind: .agent, text: "answer"),
            ChatTranscriptMessage(kind: .user, text: "/help"),
            ChatTranscriptMessage(kind: .event, text: "help output"),
            ChatTranscriptMessage(kind: .user, text: "another question"),
        ]
        // From the first real user bubble: it + the last real one = 2 (the /help
        // echo in between is skipped).
        #expect(LocalChatViewModel.undoTurnCount(through: messages[0].id, in: messages) == 2)
        // The slash echo itself contributes nothing.
        #expect(LocalChatViewModel.undoTurnCount(through: messages[2].id, in: messages) == 1)
    }
}

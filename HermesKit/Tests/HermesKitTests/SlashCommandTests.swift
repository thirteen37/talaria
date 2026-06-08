import Testing
@testable import HermesKit

/// Verifies the one shared slash-command parser used by both the app's send-path
/// routing and ``GatewayChatClient``'s `command.dispatch` fallback, so the two
/// can't drift on leading-slash stripping or argument splitting.
@Suite
struct SlashCommandTests {
    @Test
    func parsesBareNameWithNoArg() {
        let parsed = SlashCommand(parsing: "/help")
        #expect(parsed.name == "help")
        #expect(parsed.arg == "")
    }

    @Test
    func splitsNameAndArgOnFirstWhitespace() {
        let parsed = SlashCommand(parsing: "/title My Great Chat")
        #expect(parsed.name == "title")
        #expect(parsed.arg == "My Great Chat")
    }

    @Test
    func stripsMultipleLeadingSlashesAndTrimsArg() {
        let parsed = SlashCommand(parsing: "//model   gpt-5  ")
        #expect(parsed.name == "model")
        #expect(parsed.arg == "gpt-5")
    }

    @Test
    func parsesWithoutLeadingSlash() {
        // The gateway client feeds an already-stripped command; re-parsing must
        // behave identically.
        let parsed = SlashCommand(parsing: "undo")
        #expect(parsed.name == "undo")
        #expect(parsed.arg == "")
    }

    @Test
    func emptyInputYieldsEmptyNameAndArg() {
        let parsed = SlashCommand(parsing: "/")
        #expect(parsed.name == "")
        #expect(parsed.arg == "")
    }
}

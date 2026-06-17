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

    // MARK: - Pending-input set (commands Hermes accepts mid-turn)

    @Test
    func pendingInputSetMatchesGatewayContract() {
        // The gateway's pending-input set (`server.py:5931`): the commands
        // `command.dispatch` accepts while a turn is in flight.
        #expect(SlashCommand.pendingInputCommands == ["retry", "queue", "q", "steer", "plan", "goal", "undo"])
    }

    @Test
    func isPendingInputTrueForEachPendingCommand() {
        for name in ["retry", "queue", "q", "steer", "plan", "goal", "undo"] {
            #expect(SlashCommand(parsing: "/\(name)").isPendingInput, "expected /\(name) to be pending-input")
            // Arguments and surplus slashes don't change the classification.
            #expect(SlashCommand(parsing: "//\(name) some argument").isPendingInput)
        }
    }

    @Test
    func isPendingInputIsCaseInsensitive() {
        #expect(SlashCommand(parsing: "/QUEUE revisit migration").isPendingInput)
        #expect(SlashCommand(parsing: "/Steer use Swift").isPendingInput)
    }

    @Test
    func isPendingInputFalseForNonPendingCommands() {
        for name in ["help", "model", "tools", "compact", "title", "new", "reset"] {
            #expect(!SlashCommand(parsing: "/\(name)").isPendingInput, "expected /\(name) NOT to be pending-input")
        }
    }

    @Test
    func isPendingInputFalseForPlainWord() {
        // A bare word that happens to collide with no command is still classified
        // by name; an empty parse is never pending-input.
        #expect(!SlashCommand(parsing: "queueueue").isPendingInput)
        #expect(!SlashCommand(parsing: "/").isPendingInput)
    }
}

import Foundation
import HermesKit
import Testing
@testable import Talaria

@Suite
struct SlashCommandRankingTests {
    /// Build a command list from bare names (descriptions are irrelevant to ranking).
    private func commands(_ names: [String]) -> [AvailableCommand] {
        names.map { AvailableCommand(name: $0, description: "") }
    }

    @Test
    func prefixBeatsInterior() {
        let ranked = rankedSlashCommands(commands(["compact", "reset", "rerun", "secret"]), matching: "re")
        // `reset` and `rerun` are prefix matches (tier 1); `secret` is interior (tier 3).
        #expect(ranked.map(\.name) == ["reset", "rerun", "secret"])
    }

    @Test
    func exactBeatsLongerPrefix() {
        let ranked = rankedSlashCommands(commands(["modelinfo", "model"]), matching: "model")
        #expect(ranked.map(\.name) == ["model", "modelinfo"])
    }

    @Test
    func wordBoundaryBeatsInterior() {
        let ranked = rankedSlashCommands(commands(["decode", "oh-my-code"]), matching: "code")
        // `oh-my-code` matches at a separator boundary (tier 2); `decode` is interior (tier 3).
        #expect(ranked.map(\.name) == ["oh-my-code", "decode"])
    }

    @Test
    func stableWithinTier() {
        // Both are interior matches at the same tier; input order must be preserved.
        let ranked = rankedSlashCommands(commands(["abxz", "abyz"]), matching: "b")
        #expect(ranked.map(\.name) == ["abxz", "abyz"])
    }

    @Test
    func emptyQueryReturnsAllUnchanged() {
        let input = commands(["compact", "reset", "rerun"])
        let ranked = rankedSlashCommands(input, matching: "")
        #expect(ranked.map(\.name) == input.map(\.name))
    }

    @Test
    func noMatchReturnsEmpty() {
        let ranked = rankedSlashCommands(commands(["compact", "reset"]), matching: "zzz")
        #expect(ranked.isEmpty)
    }

    @Test
    func caseInsensitiveAgainstMixedCaseNames() {
        // Query arrives lowercased from the composer; names may be mixed-case.
        let ranked = rankedSlashCommands(commands(["Reset", "Compact"]), matching: "reset")
        #expect(ranked.map(\.name) == ["Reset"])
    }
}

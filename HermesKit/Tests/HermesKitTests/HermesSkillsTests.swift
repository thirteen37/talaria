import Testing
@testable import HermesKit

@Suite
struct HermesSkillsTests {
    @Test
    func parsesCheckboxStyle() {
        let text = """
        [x] commit-push  ~/.hermes/skills/commit-push
        [ ] cr           ~/.hermes/skills/cr
        [x] review       ~/.hermes/skills/review
        """
        let rows = HermesSkills.parse(text)
        #expect(rows.count == 3)
        #expect(rows[0] == SkillRow(name: "commit-push", enabled: true, path: "~/.hermes/skills/commit-push"))
        #expect(rows[1] == SkillRow(name: "cr", enabled: false, path: "~/.hermes/skills/cr"))
        #expect(rows[2] == SkillRow(name: "review", enabled: true, path: "~/.hermes/skills/review"))
    }

    @Test
    func parsesTableStyleWithHeaderAndSeparator() {
        let text = """
        name           enabled  path
        -------------  -------  ------------------------------
        commit-push    yes      ~/.hermes/skills/commit-push
        cr             no       ~/.hermes/skills/cr
        review         yes      ~/.hermes/skills/review
        """
        let rows = HermesSkills.parse(text)
        #expect(rows.count == 3)
        #expect(rows[0] == SkillRow(name: "commit-push", enabled: true, path: "~/.hermes/skills/commit-push"))
        #expect(rows[1] == SkillRow(name: "cr", enabled: false, path: "~/.hermes/skills/cr"))
    }

    @Test
    func toleratesBlankLines() {
        let text = """

        [x] alpha

        [ ] beta

        """
        let rows = HermesSkills.parse(text)
        #expect(rows.map(\.name) == ["alpha", "beta"])
    }

    @Test
    func parsesBareNamesAsEnabled() {
        let text = """
        alpha
        beta
        """
        let rows = HermesSkills.parse(text)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.enabled })
    }
}

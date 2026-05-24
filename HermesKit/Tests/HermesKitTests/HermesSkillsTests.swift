import Foundation
import Testing
@testable import HermesKit

@Suite
struct HermesSkillsTests {
    @Test
    func parsesRichBoxDrawingTable() throws {
        // Regression: the real hermes build emits a Rich box-drawing table
        // (`┃ Name ┃ Category ┃ Source ┃ Trust ┃ Status ┃`). Before this
        // parser, every row got split on the verticals as separate "names",
        // producing rows like `--`, `||`, `dogfood [ |...0n | enabled ]`.
        let url = try #require(Bundle.module.url(forResource: "Fixtures/skills-rich", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let rows = HermesSkills.parse(text)
        #expect(rows.count == 90)
        #expect(rows.first?.name == "dogfood")
        #expect(rows.first?.enabled == true)
        #expect(rows.first?.path == "builtin", "empty category should fall back to Source")
        let appleNotes = try #require(rows.first(where: { $0.name == "apple-notes" }))
        #expect(appleNotes.enabled == true)
        #expect(appleNotes.path == "apple")
        // No row should have a box-drawing artefact as a name.
        for row in rows {
            #expect(!row.name.contains("─"), "name '\(row.name)' contains a separator char")
            #expect(!row.name.contains("│"))
            #expect(!row.name.contains("┃"))
            #expect(!row.name.isEmpty)
        }
    }

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

    @Test
    func stripsBoxDrawingWrapFromInspect() {
        // Real `hermes skills inspect <id>` wraps each line in `│ … │`.
        // The previewer feeds the result into MarkdownText, so the verticals
        // and padding need to come off or the rendered preview is unreadable.
        let panel = """
        ╭─── Skill: Dogfood ───╮
        │ Name: Dogfood        │
        │                      │
        │ # Usage              │
        │                      │
        │ Steps:               │
        │   - run hermes       │
        │   - inspect          │
        ╰─── footer ───────────╯
        """
        let stripped = HermesSkills.stripBoxDrawingWrap(panel)
        #expect(stripped.contains("Name: Dogfood"))
        #expect(stripped.contains("# Usage"))
        #expect(stripped.contains("- run hermes"))
        // Border rows must be gone.
        #expect(!stripped.contains("╭"))
        #expect(!stripped.contains("╯"))
        #expect(!stripped.contains("│"))
    }

    @Test
    func parserCapturesSourceColumn() throws {
        // Builtin skills need their Source carried separately so the
        // inspect call can build a `<source>/<name>` identifier — bare
        // names trigger the registry fuzzy-search "did you mean" reply.
        let url = try #require(Bundle.module.url(forResource: "Fixtures/skills-rich", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let rows = HermesSkills.parse(text)
        let dogfood = try #require(rows.first(where: { $0.name == "dogfood" }))
        #expect(dogfood.source == "builtin")
        let scarf = try #require(rows.first(where: { $0.name == "scarf-template-author" }))
        #expect(scarf.source == "local")
    }

    @Test
    func ensureSuccessDoesNotSwallowEnvBinaryNotFound() {
        // `env: hermes: No such file or directory` happens when the local
        // admin runner can't find the hermes binary on PATH. The old matcher
        // mislabelled this as "skills command unavailable in this version".
        let result = HermesAdminResult(
            exitCode: 127,
            stdout: "",
            stderr: "env: hermes: No such file or directory\n"
        )
        do {
            try HermesSkills.ensureSuccess(result)
            #expect(Bool(false), "ensureSuccess should have thrown")
        } catch let error as HermesSkillsError {
            if case .commandFailed = error {
                // ok
            } else {
                #expect(Bool(false), "expected commandFailed, got \(error)")
            }
        } catch {
            #expect(Bool(false), "unexpected error type \(error)")
        }
    }

    @Test
    func ensureSuccessThrowsCommandUnavailableForUnknownCommand() {
        let result = HermesAdminResult(
            exitCode: 2,
            stdout: "",
            stderr: "hermes: no such command 'skills'\n"
        )
        do {
            try HermesSkills.ensureSuccess(result)
            #expect(Bool(false), "ensureSuccess should have thrown")
        } catch let error as HermesSkillsError {
            if case .commandUnavailable = error {
                // ok
            } else {
                #expect(Bool(false), "expected commandUnavailable, got \(error)")
            }
        } catch {
            #expect(Bool(false), "unexpected error type \(error)")
        }
    }
}

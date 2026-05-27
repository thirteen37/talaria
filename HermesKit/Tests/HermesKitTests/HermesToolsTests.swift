import Foundation
import Testing
@testable import HermesKit

@Suite
struct HermesToolsTests {
    @Test
    func parsesBulletFormatFromRealHermes() throws {
        // Regression: real `hermes tools list` emits lines like
        //   `  ✓ enabled  web  🔍 Web Search & Scraping`
        // The previous parser fell through to the bare "name only" arm
        // because nothing matched `[x]` brackets, leaving `name = "✓"` for
        // every row and rolling the rest into the platform column.
        let url = try #require(Bundle.module.url(forResource: "Fixtures/tools-rich", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let rows = HermesTools.parse(text)
        #expect(rows.count == 24)
        let web = try #require(rows.first(where: { $0.name == "web" }))
        #expect(web.enabled == true)
        #expect(web.platform == "🔍 Web Search & Scraping")
        let video = try #require(rows.first(where: { $0.name == "video" }))
        #expect(video.enabled == false)
        #expect(video.platform == "🎬 Video Analysis")
        // No row should be named with the literal bullet glyph or status word.
        for row in rows {
            #expect(row.name != "✓")
            #expect(row.name != "✗")
            #expect(row.name != "enabled")
            #expect(row.name != "disabled")
        }
    }

    @Test
    func parsesCheckboxStyle() {
        let text = """
        [x] Bash    posix
        [x] Read    universal
        [ ] Edit    universal
        """
        let rows = HermesTools.parse(text)
        #expect(rows.count == 3)
        #expect(rows[0] == ToolRow(name: "Bash", platform: "posix", enabled: true))
        #expect(rows[1] == ToolRow(name: "Read", platform: "universal", enabled: true))
        #expect(rows[2] == ToolRow(name: "Edit", platform: "universal", enabled: false))
    }

    @Test
    func parsesTableStyle() {
        let text = """
        name    platform   enabled
        ------  ---------  -------
        Bash    posix      yes
        Read    universal  yes
        Edit    universal  no
        """
        let rows = HermesTools.parse(text)
        #expect(rows.count == 3)
        #expect(rows[0] == ToolRow(name: "Bash", platform: "posix", enabled: true))
        #expect(rows[2] == ToolRow(name: "Edit", platform: "universal", enabled: false))
    }

    @Test
    func parsesBareNames() {
        let text = """
        alpha
        beta
        """
        let rows = HermesTools.parse(text)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.enabled })
        #expect(rows.allSatisfy { $0.platform == nil })
    }

    @Test
    func ensureSuccessDoesNotSwallowEnvBinaryNotFound() {
        // Regression: `env: hermes: No such file or directory` (PATH miss)
        // used to be mistaken for "tools subcommand missing in this hermes".
        let result = HermesAdminResult(
            exitCode: 127,
            stdout: "",
            stderr: "env: hermes: No such file or directory\n"
        )
        do {
            try HermesTools.ensureSuccess(result)
            #expect(Bool(false), "ensureSuccess should have thrown")
        } catch let error as HermesToolsError {
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
            stderr: "hermes: no such command 'tools'\n"
        )
        do {
            try HermesTools.ensureSuccess(result)
            #expect(Bool(false), "ensureSuccess should have thrown")
        } catch let error as HermesToolsError {
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

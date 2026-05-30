import Foundation
import Testing
@testable import HermesKit

@Suite
struct HermesDoctorTests {
    @Test
    func parsesRealHermesDiamondSections() throws {
        // Regression: real `hermes doctor` uses `◆ Section` headers and a
        // boxed `🩺 Hermes Doctor` banner. The previous parser knew about
        // `==`, `---`, and ALL-CAPS headers only, so the entire report
        // collapsed into one undifferentiated "Report" blob.
        let url = try #require(Bundle.module.url(forResource: "Fixtures/doctor-rich", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let sections = HermesDoctor.parseSections(text)
        // Don't pin the exact count — hermes adds sections over time.
        #expect(sections.count >= 5)
        let titles = sections.map(\.title)
        #expect(titles.contains("Security Advisories"))
        #expect(titles.contains("Python Environment"))
        #expect(titles.contains("Required Packages"))
        #expect(titles.contains("Directory Structure"))
        // The boxed banner should NOT register as its own section.
        #expect(!titles.contains(where: { $0.contains("Hermes Doctor") }))
        // Bullet items inside a section must stay in the body, not start
        // a new section.
        let pythonSection = try #require(sections.first(where: { $0.title == "Python Environment" }))
        #expect(pythonSection.body.contains("Python 3.11.15"))
    }

    @Test
    func markdownBulletsInSectionBodyAreNotMistakenForHeaders() {
        // Regression: an earlier implementation accepted `+`/`*` as alternate
        // bullet markers for section headers, which would have split this
        // section into one per bullet item. Only `◆` registers as a header.
        let text = """
        ◆ Required Packages
          * OpenAI SDK
          * Rich (terminal UI)
          + python-dotenv
        """
        let sections = HermesDoctor.parseSections(text)
        #expect(sections.count == 1)
        #expect(sections[0].title == "Required Packages")
        #expect(sections[0].body.contains("* OpenAI SDK"))
        #expect(sections[0].body.contains("+ python-dotenv"))
    }

    @Test
    func dropsBoxBannerWhenRealHeadersFollow() {
        let text = """
        ┌─────────────────────────────────────┐
        │             🩺 Hermes Doctor        │
        └─────────────────────────────────────┘

        ◆ First
          x

        ◆ Second
          y
        """
        let sections = HermesDoctor.parseSections(text)
        #expect(sections.count == 2)
        #expect(sections[0].title == "First")
        #expect(sections[1].title == "Second")
    }

    @Test
    func splitsOnDoubleEqualHeaders() {
        let text = """
        == System ==
        OS: macOS 14.5
        Arch: arm64

        == Configuration ==
        HERMES_HOME: /Users/dev/.hermes
        """
        let sections = HermesDoctor.parseSections(text)
        #expect(sections.count == 2)
        #expect(sections[0].title == "System")
        #expect(sections[0].body.contains("OS: macOS 14.5"))
        #expect(sections[1].title == "Configuration")
        #expect(sections[1].body.contains("HERMES_HOME"))
    }

    @Test
    func splitsOnTripleDashSeparators() {
        let text = """
        --- Versions ---
        hermes 1.2.3
        --- Health ---
        OK
        """
        let sections = HermesDoctor.parseSections(text)
        #expect(sections.count == 2)
        #expect(sections[0].title == "Versions")
        #expect(sections[1].title == "Health")
    }

    @Test
    func recognisesAllCapsHeadersAfterBlankLine() {
        let text = """
        Some preamble

        VERSIONS
        hermes 1.2.3

        HEALTH
        OK
        """
        let sections = HermesDoctor.parseSections(text)
        #expect(sections.count == 3)
        #expect(sections[0].title == "Summary")
        #expect(sections[1].title == "VERSIONS")
        #expect(sections[2].title == "HEALTH")
    }

    @Test
    func handlesNoHeaders() {
        let text = """
        Everything looks fine.
        Nothing to report.
        """
        let sections = HermesDoctor.parseSections(text)
        #expect(sections.count == 1)
        #expect(sections[0].body.contains("Nothing to report"))
    }

    @Test
    func suggestsFixDetectsTheTip() throws {
        // The rich fixture ends with "Tip: run 'hermes doctor --fix' …".
        let url = try #require(Bundle.module.url(forResource: "Fixtures/doctor-rich", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(HermesDoctor.suggestsFix(text))
    }

    @Test
    func suggestsFixIsFalseWithoutTheTip() {
        #expect(!HermesDoctor.suggestsFix("Everything looks fine.\nNothing to report."))
    }

    @Test
    func runPopulatesSuggestsFixFromOutput() async throws {
        let runner = RecordingAdminRunner(result: HermesAdminResult(
            exitCode: 1,
            stdout: "Found 1 issue.\n\nTip: run 'hermes doctor --fix' to auto-fix what's possible.\n",
            stderr: ""
        ))
        let report = try await HermesDoctor.run(runner: runner)
        #expect(report.suggestsFix)
    }

    @Test
    func runFixIssuesFixSubcommandAndParses() async throws {
        let runner = RecordingAdminRunner(result: HermesAdminResult(
            exitCode: 0,
            stdout: """
            ◆ Security Advisories
              Patched advisory CVE-1234.

            ◆ Required Packages
              Installed python-dotenv.
            """,
            stderr: ""
        ))
        let report = try await HermesDoctor.runFix(runner: runner)
        #expect(runner.received == [["doctor", "--fix"]])
        let titles = report.sections.map(\.title)
        #expect(titles.contains("Security Advisories"))
        #expect(titles.contains("Required Packages"))
        #expect(report.exitCode == 0)
    }

    @Test
    func lineStatusClassifiesLeadingGlyphs() {
        // OK glyph, with the indentation real doctor output uses.
        #expect(HermesDoctor.lineStatus("  ✓ Python 3.11.15") == .ok)
        // Warning glyph.
        #expect(HermesDoctor.lineStatus("  ⚠ discord.py (optional, not installed)") == .warning)
        // Hint arrow at a deeper indent.
        #expect(HermesDoctor.lineStatus("    → No Codex credentials stored.") == .hint)
        // Both failure glyphs doctor may emit.
        #expect(HermesDoctor.lineStatus("✗ something broke") == .failure)
        #expect(HermesDoctor.lineStatus("✖ broke") == .failure)
        // Summary / plain prose carries no leading glyph.
        #expect(HermesDoctor.lineStatus("Found 1 issue(s) to address:") == .plain)
        #expect(HermesDoctor.lineStatus("  1. Run 'hermes setup' to configure missing API keys") == .plain)
        // Empty / whitespace-only.
        #expect(HermesDoctor.lineStatus("") == .plain)
        #expect(HermesDoctor.lineStatus("   \t ") == .plain)
    }

    @Test
    func lineStatusMatchesRichFixtureLines() throws {
        // Drive a couple of cases straight from the real fixture so the
        // classifier stays honest about the glyphs hermes actually prints.
        let url = try #require(Bundle.module.url(forResource: "Fixtures/doctor-rich", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let okLine = try #require(lines.first(where: { $0.contains("Python 3.11.15") }))
        #expect(HermesDoctor.lineStatus(okLine) == .ok)
        let warningLine = try #require(lines.first(where: { $0.contains("discord.py (optional, not installed)") }))
        #expect(HermesDoctor.lineStatus(warningLine) == .warning)
        let hintLine = try #require(lines.first(where: { $0.contains("No Codex credentials stored") }))
        #expect(HermesDoctor.lineStatus(hintLine) == .hint)
    }

    @Test
    func runFixThrowsOnEmptyNonZeroOutput() async {
        let runner = RecordingAdminRunner(result: HermesAdminResult(
            exitCode: 2,
            stdout: "",
            stderr: "boom\n"
        ))
        do {
            _ = try await HermesDoctor.runFix(runner: runner)
            #expect(Bool(false), "runFix should have thrown")
        } catch let error as HermesDoctorError {
            if case .commandFailed = error {
                // ok
            } else {
                #expect(Bool(false), "expected commandFailed, got \(error)")
            }
        } catch {
            #expect(Bool(false), "unexpected error type \(error)")
        }
    }
}

/// Records the commands it receives so tests can assert on the arguments
/// `HermesDoctor` issues, while returning canned output.
private final class RecordingAdminRunner: HermesAdminRunning, @unchecked Sendable {
    let result: HermesAdminResult
    private(set) var received: [[String]] = []

    init(result: HermesAdminResult) {
        self.result = result
    }

    func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult {
        received.append(command.arguments)
        return result
    }
}

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
}

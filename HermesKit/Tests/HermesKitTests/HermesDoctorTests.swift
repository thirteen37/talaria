import Testing
@testable import HermesKit

@Suite
struct HermesDoctorTests {
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

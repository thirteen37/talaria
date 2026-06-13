import Foundation
import Testing
@testable import HermesKit

@Suite
struct MarkdownFrontmatterTests {
    @Test
    func splitsLeadingYAMLFrontmatterFromBody() throws {
        let text = """
        ---
        name: foo
        description: A skill
        ---
        # Heading

        Body text.
        """
        let parts = try #require(MarkdownFrontmatter.split(text))
        #expect(parts.frontmatter == "---\nname: foo\ndescription: A skill\n---\n")
        #expect(parts.body == "# Heading\n\nBody text.")
        // Exact reconstruction — no characters dropped at the boundary.
        #expect(parts.frontmatter + parts.body == text)
    }

    @Test
    func returnsNilWhenNoOpeningFence() {
        #expect(MarkdownFrontmatter.split("# Just markdown\n\nNo frontmatter.") == nil)
    }

    @Test
    func returnsNilWhenOpeningFenceHasNoClose() {
        #expect(MarkdownFrontmatter.split("---\nname: foo\n# never closed\n") == nil)
    }

    @Test
    func handlesCarriageReturns() throws {
        let text = "---\r\nname: foo\r\n---\r\n# Body\r\n"
        let parts = try #require(MarkdownFrontmatter.split(text))
        #expect(parts.frontmatter == "---\r\nname: foo\r\n---\r\n")
        #expect(parts.body == "# Body\r\n")
        #expect(parts.frontmatter + parts.body == text)
    }

    @Test
    func handlesFrontmatterWithEmptyBody() throws {
        let text = "---\nname: foo\n---\n"
        let parts = try #require(MarkdownFrontmatter.split(text))
        #expect(parts.frontmatter == text)
        #expect(parts.body.isEmpty)
    }
}

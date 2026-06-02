import Foundation
import Testing
@testable import HermesKit

@Suite
struct MarkdownSyntaxHighlighterTests {
    // MARK: - Helpers

    /// Substrings (against the NSString view) of every token of `kind`, in order.
    private func substrings(
        _ kind: MarkdownTokenKind,
        in text: String
    ) -> [String] {
        let ns = text as NSString
        return MarkdownSyntaxHighlighter.tokens(in: text)
            .filter { $0.kind == kind }
            .map { ns.substring(with: $0.range) }
    }

    // MARK: - Headings

    @Test
    func tokenizesAtxHeading() {
        let text = "## Section title"
        #expect(substrings(.punctuation, in: text) == ["##"])
        #expect(substrings(.heading, in: text) == ["Section title"])
    }

    @Test
    func hashWithoutSpaceIsNotHeading() {
        // A `#tag`-style token (no space after the hashes) isn't an ATX heading.
        let text = "#tag here"
        #expect(substrings(.heading, in: text).isEmpty)
        #expect(substrings(.punctuation, in: text).isEmpty)
    }

    @Test
    func sevenHashesIsNotHeading() {
        let text = "####### too many"
        #expect(substrings(.heading, in: text).isEmpty)
    }

    // MARK: - Emphasis & strong

    @Test
    func tokenizesStrongAndEmphasis() {
        let text = "use *care* and **always** verify"
        #expect(substrings(.emphasis, in: text) == ["*care*"])
        #expect(substrings(.strong, in: text) == ["**always**"])
    }

    @Test
    func underscoresAreNotEmphasis() {
        // snake_case identifiers in a system prompt must stay plain.
        let text = "set the agent_system_prompt value"
        #expect(substrings(.emphasis, in: text).isEmpty)
        #expect(substrings(.strong, in: text).isEmpty)
    }

    @Test
    func bareAsteriskArithmeticIsNotEmphasis() {
        // `a * b` has a space hugging the asterisk on both sides, so it's not a
        // valid emphasis run.
        let text = "compute a * b * c"
        #expect(substrings(.emphasis, in: text).isEmpty)
    }

    // MARK: - Code

    @Test
    func tokenizesInlineCodeSpan() {
        let text = "run `hermes dashboard` first"
        #expect(substrings(.code, in: text) == ["`hermes dashboard`"])
    }

    @Test
    func tokenizesFencedCodeBlock() {
        let text = """
        before
        ```swift
        let x = 1
        ```
        after
        """
        // Every line from the opening fence through the closing fence is code.
        #expect(substrings(.code, in: text) == ["```swift", "let x = 1", "```"])
    }

    @Test
    func emphasisInsideFenceIsNotTokenized() {
        let text = """
        ```
        *not emphasis*
        ```
        """
        #expect(substrings(.emphasis, in: text).isEmpty)
        #expect(substrings(.code, in: text) == ["```", "*not emphasis*", "```"])
    }

    // MARK: - Lists, blockquotes, breaks

    @Test
    func tokenizesBulletAndOrderedListMarkers() {
        let text = """
        - first
        2. second
        """
        #expect(substrings(.listMarker, in: text) == ["-", "2."])
    }

    @Test
    func tokenizesBlockquote() {
        let text = "> quoted line"
        #expect(substrings(.blockquote, in: text) == [">"])
    }

    @Test
    func tokenizesThematicBreak() {
        let text = "---"
        #expect(substrings(.thematicBreak, in: text) == ["---"])
        // A single dash + space is a list marker, not a thematic break.
        #expect(substrings(.thematicBreak, in: "- item").isEmpty)
    }

    // MARK: - Links

    @Test
    func tokenizesLink() {
        let text = "see [the docs](https://example.com) for more"
        #expect(substrings(.link, in: text) == ["[the docs]"])
        #expect(substrings(.url, in: text) == ["(https://example.com)"])
    }

    @Test
    func unclosedLinkIsLeftPlain() {
        let text = "an [unclosed link"
        #expect(substrings(.link, in: text).isEmpty)
    }

    // MARK: - Robustness

    @Test
    func emptyTextProducesNoTokens() {
        #expect(MarkdownSyntaxHighlighter.tokens(in: "").isEmpty)
    }

    @Test
    func tokenRangesStayWithinText() {
        // Mixed constructs across lines: every token range must be valid against
        // the NSString view (the editor relies on this to apply attributes).
        let text = """
        # Title
        - a *b* `c` [d](e)
        > quote
        ```
        fenced
        ```
        """
        let ns = text as NSString
        for token in MarkdownSyntaxHighlighter.tokens(in: text) {
            #expect(token.range.location >= 0)
            #expect(token.range.location + token.range.length <= ns.length)
        }
    }
}

import Foundation
import Testing
@testable import HermesKit

@Suite
struct YAMLSyntaxHighlighterTests {
    // MARK: - Helpers

    /// Substrings (against the NSString view) of every token of `kind`, in order.
    private func substrings(
        _ kind: YAMLTokenKind,
        in text: String
    ) -> [String] {
        let ns = text as NSString
        return YAMLSyntaxHighlighter.tokens(in: text)
            .filter { $0.kind == kind }
            .map { ns.substring(with: $0.range) }
    }

    // MARK: - Tests

    @Test
    func tokenizesCommentLine() {
        let text = "# just a comment"
        #expect(substrings(.comment, in: text) == ["# just a comment"])
    }

    @Test
    func fullLineCommentWithColonIsNotAKey() {
        // A `# ...` comment that happens to contain a `: ` must stay a single
        // comment token, not be split with the text before the colon colored as
        // a key.
        let text = "# Note: see docs"
        #expect(substrings(.comment, in: text) == ["# Note: see docs"])
        #expect(substrings(.key, in: text).isEmpty)
    }

    @Test
    func indentedCommentWithColonIsNotAKey() {
        let text = "  # key: value"
        #expect(substrings(.comment, in: text) == ["# key: value"])
        #expect(substrings(.key, in: text).isEmpty)
    }

    @Test
    func tokenizesKeyAndScalarValue() {
        // A plain `key: value` mapping entry: the key name and the numeric value
        // get distinct token kinds.
        let text = "model_context_length: 200000"
        #expect(substrings(.key, in: text) == ["model_context_length"])
        #expect(substrings(.scalar, in: text) == ["200000"])
    }

    @Test
    func tokenizesBooleanAndNullScalars() {
        let text = "streaming: true\nfallback: null"
        #expect(substrings(.key, in: text) == ["streaming", "fallback"])
        #expect(substrings(.scalar, in: text) == ["true", "null"])
    }

    @Test
    func multiWordPlainScalarDoesNotHighlightEmbeddedNumber() {
        // A plain (unquoted) YAML scalar can span several words, so the embedded
        // `2` is part of the string value, not a number to color.
        let text = "name: My Profile 2"
        #expect(substrings(.key, in: text) == ["name"])
        #expect(substrings(.scalar, in: text).isEmpty)
    }

    @Test
    func multiWordPlainScalarDoesNotHighlightEmbeddedKeyword() {
        let text = "note: there is no value"
        #expect(substrings(.key, in: text) == ["note"])
        #expect(substrings(.scalar, in: text).isEmpty)
    }

    @Test
    func soleKeywordValueWithTrailingCommentIsScalar() {
        // The keyword is still the sole value token (only a comment follows), so
        // it is colored.
        let text = "streaming: true  # default"
        #expect(substrings(.scalar, in: text) == ["true"])
        #expect(substrings(.comment, in: text) == ["# default"])
    }

    @Test
    func tokenizesQuotedStringValue() {
        // A quoted scalar (even a numeric-looking one) is a string, quotes included.
        let text = "pin: \"123\""
        #expect(substrings(.key, in: text) == ["pin"])
        #expect(substrings(.string, in: text) == ["\"123\""])
        // The quoted "123" must NOT also be reported as a numeric scalar.
        #expect(substrings(.scalar, in: text).isEmpty)
    }

    @Test
    func tokenizesNestedMappingWithIndentation() {
        let text = """
        agent:
          streaming: true
        """
        #expect(substrings(.key, in: text) == ["agent", "streaming"])
        #expect(substrings(.scalar, in: text) == ["true"])
    }

    @Test
    func tokenizesBlockSequenceMarkers() {
        let text = """
        toolsets:
          - files
          - web
        """
        #expect(substrings(.key, in: text) == ["toolsets"])
        // The dash markers are punctuation; the plain string items fall through.
        #expect(substrings(.punctuation, in: text) == ["-", "-"])
    }

    @Test
    func hashInsideQuotedStringIsNotAComment() {
        let text = "name: \"a # b\""
        #expect(substrings(.comment, in: text).isEmpty)
        #expect(substrings(.string, in: text) == ["\"a # b\""])
    }

    @Test
    func trailingCommentAfterValueIsTokenized() {
        let text = "model_context_length: 200000  # tokens"
        #expect(substrings(.scalar, in: text) == ["200000"])
        #expect(substrings(.comment, in: text) == ["# tokens"])
    }

    @Test
    func invalidYAMLDoesNotCrashAndStillTokenizesKey() {
        // Mid-edit, unterminated flow collection: the lexer must never throw and
        // should still color what it can (the leading key).
        let text = "key: [unterminated"
        let tokens = YAMLSyntaxHighlighter.tokens(in: text)
        #expect(!tokens.isEmpty)
        #expect(substrings(.key, in: text) == ["key"])
    }

    @Test
    func tokenizesDocumentMarkers() {
        let text = "---\nmodel: x\n..."
        #expect(substrings(.punctuation, in: text).contains("---"))
        #expect(substrings(.punctuation, in: text).contains("..."))
    }

    @Test
    func tokenizesQuotedKey() {
        let text = "\"quoted key\": value"
        #expect(substrings(.key, in: text) == ["\"quoted key\""])
    }
}

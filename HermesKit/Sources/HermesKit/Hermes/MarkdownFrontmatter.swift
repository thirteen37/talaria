import Foundation

/// Splits a markdown document's leading YAML frontmatter (a `---`-fenced block
/// at the very start) from its body, so each half can be highlighted by the
/// appropriate theme (YAML for the frontmatter, markdown for the body).
public enum MarkdownFrontmatter {
    /// Returns the `frontmatter` (the opening `---`, the YAML, the closing
    /// `---`, and that closing fence's trailing newline) and the `body` (the
    /// remainder). `frontmatter + body` reconstructs the input exactly.
    /// Returns `nil` when the document has no frontmatter — the first line isn't
    /// a `---` fence, or the opening fence never closes.
    public static func split(_ text: String) -> (frontmatter: String, body: String)? {
        var lineStart = text.startIndex
        var isFirstLine = true
        while true {
            // Scan to the line's terminating newline. `Character.isNewline`
            // treats a `\r\n` pair as one newline grapheme, so CRLF documents
            // split correctly (a plain `firstIndex(of: "\n")` would miss it).
            var cursor = lineStart
            while cursor < text.endIndex, !text[cursor].isNewline {
                cursor = text.index(after: cursor)
            }
            let line = text[lineStart..<cursor].trimmingCharacters(in: .whitespacesAndNewlines)
            let nextStart = cursor < text.endIndex ? text.index(after: cursor) : text.endIndex
            if isFirstLine {
                guard line == "---" else { return nil }
                isFirstLine = false
            } else if line == "---" {
                // Frontmatter runs through this closing fence's trailing newline.
                let frontmatter = String(text[text.startIndex..<nextStart])
                let body = String(text[nextStart...])
                return (frontmatter, body)
            }
            if cursor >= text.endIndex { break }
            lineStart = nextStart
        }
        return nil
    }
}

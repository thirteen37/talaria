import Foundation

/// The classes of token the Markdown highlighter recognizes. Anything it can't
/// confidently classify is left untokenized rather than guessed at.
public enum MarkdownTokenKind: Sendable, Equatable {
    case heading
    case strong
    case emphasis
    case code
    case listMarker
    case blockquote
    case link
    case url
    case punctuation
    case thematicBreak
}

/// A classified span of the source text. `range` is an `NSRange` against the
/// `NSString` (UTF-16) view so the same tokens drive both an AppKit/UIKit
/// `textStorage` and a Foundation `AttributedString` without re-mapping indices.
public struct MarkdownToken: Sendable, Equatable {
    public let range: NSRange
    public let kind: MarkdownTokenKind

    public init(range: NSRange, kind: MarkdownTokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// A pragmatic, line-based Markdown lexer for syntax highlighting. It is
/// Foundation-only and **never throws**: it runs on every edit over text that
/// may be invalid mid-keystroke, coloring what it can and leaving the rest
/// plain. It is deliberately not a full CommonMark parser — it targets the
/// common constructs that appear in a `SOUL.md` / system-prompt document:
/// ATX headings, fenced code blocks, inline code spans, `*`/`**` emphasis,
/// bullet/ordered list markers, blockquotes, links, and thematic breaks.
///
/// Two pragmatic simplifications keep false positives low in technical prompts:
/// inline spans never cross a line boundary, and `_`/`__` are **not** treated as
/// emphasis (so `snake_case` identifiers stay plain) — only `*`/`**` are.
public enum MarkdownSyntaxHighlighter {
    public static func tokens(in text: String) -> [MarkdownToken] {
        var tokens: [MarkdownToken] = []
        var offset = 0
        var inFence = false
        var fenceChar: unichar = 0
        for line in text.components(separatedBy: "\n") {
            let nsLine = line as NSString
            tokenize(line: nsLine, base: offset, inFence: &inFence, fenceChar: &fenceChar, into: &tokens)
            offset += nsLine.length + 1 // + the consumed "\n"
        }
        return tokens
    }

    // MARK: - Character constants

    private static let space: unichar = 0x20
    private static let tab: unichar = 0x09
    private static let hash: unichar = 0x23 // #
    private static let gt: unichar = 0x3E // >
    private static let dash: unichar = 0x2D // -
    private static let asterisk: unichar = 0x2A // *
    private static let underscore: unichar = 0x5F // _
    private static let plus: unichar = 0x2B // +
    private static let dot: unichar = 0x2E // .
    private static let rparen: unichar = 0x29 // )
    private static let lparen: unichar = 0x28 // (
    private static let lbracket: unichar = 0x5B // [
    private static let rbracket: unichar = 0x5D // ]
    private static let backtick: unichar = 0x60 // `
    private static let tilde: unichar = 0x7E // ~

    private static func isSpace(_ c: unichar) -> Bool { c == space || c == tab }
    private static func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }

    // MARK: - Per-line lexing

    private static func tokenize(
        line: NSString,
        base: Int,
        inFence: inout Bool,
        fenceChar: inout unichar,
        into tokens: inout [MarkdownToken]
    ) {
        let len = line.length
        func char(_ i: Int) -> unichar { line.character(at: i) }
        func emit(_ start: Int, _ length: Int, _ kind: MarkdownTokenKind) {
            guard length > 0, start >= 0, start + length <= len else { return }
            tokens.append(MarkdownToken(range: NSRange(location: base + start, length: length), kind: kind))
        }

        var i = 0
        while i < len, isSpace(char(i)) { i += 1 }

        // Inside a fenced code block: the whole line is code. A run of >= 3 of
        // the opening fence character closes it.
        if inFence {
            emit(0, len, .code)
            if i < len, char(i) == fenceChar, fenceRun(line, at: i, len: len, of: fenceChar) >= 3 {
                inFence = false
            }
            return
        }

        // Opening fence (``` or ~~~).
        if i < len, char(i) == backtick || char(i) == tilde, fenceRun(line, at: i, len: len, of: char(i)) >= 3 {
            emit(0, len, .code)
            inFence = true
            fenceChar = char(i)
            return
        }

        guard i < len else { return }

        // Thematic break: a line of only `-`, `*`, or `_` (>= 3 of one kind),
        // possibly spaced. Checked before list markers so `---` isn't read as a
        // one-item bullet list.
        if isThematicBreak(line, from: i, len: len) {
            emit(i, len - i, .thematicBreak)
            return
        }

        // ATX heading: 1–6 `#` followed by a space (or end of line).
        if char(i) == hash {
            var h = i
            while h < len, char(h) == hash { h += 1 }
            let hashes = h - i
            if hashes <= 6, h == len || isSpace(char(h)) {
                emit(i, hashes, .punctuation)
                var t = h
                while t < len, isSpace(char(t)) { t += 1 }
                emit(t, len - t, .heading)
                return
            }
        }

        // Blockquote marker, then fall through to inline scanning of the rest.
        if char(i) == gt {
            emit(i, 1, .blockquote)
            i += 1
            while i < len, isSpace(char(i)) { i += 1 }
        } else if let markerLen = listMarkerLength(line, at: i, len: len) {
            // Bullet (`- `, `* `, `+ `) or ordered (`1.`, `2)`) list marker.
            emit(i, markerLen, .listMarker)
            i += markerLen
            while i < len, isSpace(char(i)) { i += 1 }
        }

        scanInline(line, from: i, len: len, emit: emit)
    }

    /// Number of consecutive `c` characters starting at `i`.
    private static func fenceRun(_ line: NSString, at i: Int, len: Int, of c: unichar) -> Int {
        var j = i
        while j < len, line.character(at: j) == c { j += 1 }
        return j - i
    }

    private static func isThematicBreak(_ line: NSString, from i: Int, len: Int) -> Bool {
        let c = line.character(at: i)
        guard c == dash || c == asterisk || c == underscore else { return false }
        var count = 0
        var j = i
        while j < len {
            let ch = line.character(at: j)
            if ch == c { count += 1 } else if !isSpace(ch) { return false }
            j += 1
        }
        return count >= 3
    }

    /// Length of a list marker at `i` (`- `, `* `, `+ `, `1.`, `1)`), or nil.
    private static func listMarkerLength(_ line: NSString, at i: Int, len: Int) -> Int? {
        let c = line.character(at: i)
        if c == dash || c == asterisk || c == plus {
            if i + 1 == len || (i + 1 < len && isSpace(line.character(at: i + 1))) { return 1 }
            return nil
        }
        if isDigit(c) {
            var j = i
            while j < len, isDigit(line.character(at: j)) { j += 1 }
            guard j < len, line.character(at: j) == dot || line.character(at: j) == rparen else { return nil }
            let end = j + 1
            if end == len || (end < len && isSpace(line.character(at: end))) { return end - i }
            return nil
        }
        return nil
    }

    // MARK: - Inline scanning

    private static func scanInline(
        _ line: NSString,
        from start: Int,
        len: Int,
        emit: (Int, Int, MarkdownTokenKind) -> Void
    ) {
        func char(_ j: Int) -> unichar { line.character(at: j) }
        var i = start
        while i < len {
            let c = char(i)
            if c == backtick {
                // Inline code span up to the next backtick on this line.
                var j = i + 1
                while j < len, char(j) != backtick { j += 1 }
                if j < len {
                    emit(i, j - i + 1, .code)
                    i = j + 1
                    continue
                }
                i += 1
                continue
            }
            if c == asterisk {
                if i + 1 < len, char(i + 1) == asterisk {
                    if let close = findRun(line, of: asterisk, count: 2, from: i + 2, len: len) {
                        emit(i, close + 2 - i, .strong)
                        i = close + 2
                        continue
                    }
                } else if let close = findEmphasis(line, from: i, len: len) {
                    emit(i, close - i + 1, .emphasis)
                    i = close + 1
                    continue
                }
                i += 1
                continue
            }
            if c == lbracket, let link = parseLink(line, from: i, len: len) {
                emit(i, link.textLen, .link)
                emit(link.urlStart, link.urlLen, .url)
                i = link.end
                continue
            }
            i += 1
        }
    }

    /// Start index of the first run of `count` consecutive `c` at or after `from`.
    private static func findRun(_ line: NSString, of c: unichar, count: Int, from: Int, len: Int) -> Int? {
        var j = from
        while j + count <= len {
            var k = 0
            while k < count, line.character(at: j + k) == c { k += 1 }
            if k == count { return j }
            j += 1
        }
        return nil
    }

    /// Closing `*` for single-`*` emphasis opened at `i`, applying CommonMark-ish
    /// flanking: the opener must hug text (no space right after the `*`) and the
    /// closer must hug text (no space right before it). Returns nil when no valid
    /// closer is on the line — which also rejects bare `a * b` arithmetic.
    private static func findEmphasis(_ line: NSString, from i: Int, len: Int) -> Int? {
        guard i + 1 < len, !isSpace(line.character(at: i + 1)) else { return nil }
        var j = i + 1
        while j < len {
            if line.character(at: j) == asterisk, !isSpace(line.character(at: j - 1)) { return j }
            j += 1
        }
        return nil
    }

    /// Parses `[text](url)` starting at the `[` index. Returns the `[text]` length,
    /// the `(url)` span, and the index just past the closing `)`.
    private static func parseLink(
        _ line: NSString,
        from i: Int,
        len: Int
    ) -> (textLen: Int, urlStart: Int, urlLen: Int, end: Int)? {
        var j = i + 1
        while j < len, line.character(at: j) != rbracket { j += 1 }
        guard j < len else { return nil } // ']'
        let rb = j
        guard rb + 1 < len, line.character(at: rb + 1) == lparen else { return nil }
        var k = rb + 2
        while k < len, line.character(at: k) != rparen { k += 1 }
        guard k < len else { return nil } // ')'
        let rp = k
        return (textLen: rb - i + 1, urlStart: rb + 1, urlLen: rp - rb, end: rp + 1)
    }
}

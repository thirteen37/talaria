import Foundation

/// The classes of token the YAML highlighter recognizes. Anything it can't
/// confidently classify (plain string values, anchors, aliases, multiline
/// scalars) is simply left untokenized rather than guessed at.
public enum YAMLTokenKind: Sendable, Equatable {
    case comment
    case key
    case string
    case scalar
    case punctuation
}

/// A classified span of the source text. `range` is an `NSRange` against the
/// `NSString` (UTF-16) view so the same tokens drive both an AppKit/UIKit
/// `textStorage` and a Foundation `AttributedString` without re-mapping indices.
public struct YAMLToken: Sendable, Equatable {
    public let range: NSRange
    public let kind: YAMLTokenKind

    public init(range: NSRange, kind: YAMLTokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// A pragmatic, line-based YAML lexer for syntax highlighting. It is
/// Foundation-only and **never throws**: it is designed to run on every edit
/// over text that may be invalid mid-keystroke, coloring what it can and
/// leaving the rest plain. It targets the YAML this app emits via
/// `YAMLConfigCodec.yaml(from:)`; exotic YAML (anchors/aliases/folded scalars)
/// falls through unhighlighted.
public enum YAMLSyntaxHighlighter {
    public static func tokens(in text: String) -> [YAMLToken] {
        var tokens: [YAMLToken] = []
        var offset = 0
        for line in text.components(separatedBy: "\n") {
            let nsLine = line as NSString
            tokenize(line: nsLine, base: offset, into: &tokens)
            offset += nsLine.length + 1 // + the consumed "\n"
        }
        return tokens
    }

    // MARK: - Per-line lexing

    private static let space: unichar = 0x20
    private static let tab: unichar = 0x09
    private static let hash: unichar = 0x23 // #
    private static let colon: unichar = 0x3A // :
    private static let dash: unichar = 0x2D // -
    private static let dot: unichar = 0x2E // .
    private static let backslash: unichar = 0x5C // \
    private static let singleQuote: unichar = 0x27 // '
    private static let doubleQuote: unichar = 0x22 // "

    private static func isSpace(_ c: unichar) -> Bool { c == space || c == tab }

    private static func tokenize(line: NSString, base: Int, into tokens: inout [YAMLToken]) {
        let len = line.length
        func char(_ i: Int) -> unichar { line.character(at: i) }
        func emit(_ start: Int, _ length: Int, _ kind: YAMLTokenKind) {
            guard length > 0 else { return }
            tokens.append(YAMLToken(range: NSRange(location: base + start, length: length), kind: kind))
        }

        var i = 0
        while i < len, isSpace(char(i)) { i += 1 }
        guard i < len else { return }

        // Document markers `---` / `...` at the start of a line.
        if let markerLen = documentMarker(line, at: i, len: len) {
            emit(i, markerLen, .punctuation)
            i += markerLen
            scanValue(line, from: i, len: len, base: base, emit: emit)
            return
        }

        // Leading block-sequence markers: `- ` (possibly several, e.g. `- - x`).
        while i < len, char(i) == dash, i + 1 == len || isSpace(char(i + 1)) {
            emit(i, 1, .punctuation)
            i += 1
            while i < len, isSpace(char(i)) { i += 1 }
        }
        guard i < len else { return }

        // A `key:` mapping entry (quoted or plain).
        if let (keyLen, afterColon) = parseKey(line, from: i, len: len) {
            emit(i, keyLen, .key)
            i = afterColon
            while i < len, isSpace(char(i)) { i += 1 }
        }

        scanValue(line, from: i, len: len, base: base, emit: emit)
    }

    /// Length (3) if `line` has a `---` or `...` document marker at `i` followed
    /// by whitespace or end of line, else nil.
    private static func documentMarker(_ line: NSString, at i: Int, len: Int) -> Int? {
        guard i + 3 <= len else { return nil }
        let c = line.character(at: i)
        guard c == dash || c == dot else { return nil }
        guard line.character(at: i + 1) == c, line.character(at: i + 2) == c else { return nil }
        guard i + 3 == len || isSpace(line.character(at: i + 3)) else { return nil }
        return 3
    }

    /// Parses a mapping key starting at `i` (a quoted scalar or a plain run up to
    /// an unquoted `:` that is followed by whitespace or end of line). Returns the
    /// key's length and the index just past the colon, or nil when this isn't a
    /// `key:` entry.
    private static func parseKey(_ line: NSString, from i: Int, len: Int) -> (length: Int, afterColon: Int)? {
        func char(_ j: Int) -> unichar { line.character(at: j) }
        let first = char(i)

        if first == doubleQuote || first == singleQuote {
            let close = closingQuote(line, open: i, quote: first, len: len)
            // Unterminated quote: a string, but not a complete key.
            guard close < len else { return nil }
            var j = close + 1
            while j < len, isSpace(char(j)) { j += 1 }
            guard j < len, char(j) == colon, j + 1 == len || isSpace(char(j + 1)) else { return nil }
            return (close - i + 1, j + 1)
        }

        var j = i
        while j < len {
            let c = char(j)
            if c == colon, j + 1 == len || isSpace(char(j + 1)) {
                var end = j
                while end > i, isSpace(char(end - 1)) { end -= 1 }
                guard end > i else { return nil }
                return (end - i, j + 1)
            }
            // A comment or a quote before any `key:` colon means this line isn't a
            // plain mapping entry — let the value scanner handle it. The `j == i`
            // case catches a region that *starts* with `#` (a full-line comment
            // whose text happens to contain a colon).
            if c == hash, j == i || isSpace(char(j - 1)) { return nil }
            if c == doubleQuote || c == singleQuote { return nil }
            j += 1
        }
        return nil
    }

    /// Scans the value region (everything after an optional `key:`) to end of
    /// line, emitting string / scalar / comment tokens. Plain unquoted strings
    /// are left untokenized. A bool/null/number is only colored as a `.scalar`
    /// when it is the *sole* token of the value — a plain YAML scalar may span
    /// several words (`name: My Profile 2`), and those embedded words belong to
    /// the string, not to a separate scalar.
    private static func scanValue(
        _ line: NSString,
        from start: Int,
        len: Int,
        base: Int,
        emit: (Int, Int, YAMLTokenKind) -> Void
    ) {
        func char(_ j: Int) -> unichar { line.character(at: j) }
        var i = start
        while i < len, isSpace(char(i)) { i += 1 }
        guard i < len else { return }

        // The whole value region is a comment.
        if char(i) == hash {
            emit(i, len - i, .comment)
            return
        }

        // A quoted scalar: color the string; only a trailing comment may follow.
        if char(i) == doubleQuote || char(i) == singleQuote {
            let close = closingQuote(line, open: i, quote: char(i), len: len)
            let end = min(close, len - 1)
            emit(i, end - i + 1, .string)
            emitTrailingComment(line, from: end + 1, len: len, emit: emit)
            return
        }

        // A bare value: locate any end-of-line comment, then test the content
        // between the value start and the comment for a lone typed scalar.
        let contentStart = i
        var commentStart = len
        var j = i
        while j < len {
            if char(j) == hash, j > contentStart, isSpace(char(j - 1)) { commentStart = j; break }
            j += 1
        }
        var contentEnd = commentStart
        while contentEnd > contentStart, isSpace(char(contentEnd - 1)) { contentEnd -= 1 }

        if contentEnd > contentStart, !containsWhitespace(line, from: contentStart, to: contentEnd) {
            let word = line.substring(with: NSRange(location: contentStart, length: contentEnd - contentStart))
            if isScalarKeyword(word) || isNumber(word) {
                emit(contentStart, contentEnd - contentStart, .scalar)
            }
        }

        if commentStart < len {
            emit(commentStart, len - commentStart, .comment)
        }
    }

    /// Emits a comment token for a trailing `# ...` after a quoted value, if one
    /// follows (skipping intervening whitespace).
    private static func emitTrailingComment(
        _ line: NSString,
        from start: Int,
        len: Int,
        emit: (Int, Int, YAMLTokenKind) -> Void
    ) {
        var i = start
        while i < len, isSpace(line.character(at: i)) { i += 1 }
        guard i < len, line.character(at: i) == hash else { return }
        emit(i, len - i, .comment)
    }

    private static func containsWhitespace(_ line: NSString, from start: Int, to end: Int) -> Bool {
        var i = start
        while i < end {
            if isSpace(line.character(at: i)) { return true }
            i += 1
        }
        return false
    }

    /// Index of the closing quote for a string opened at `open`, or `len` when the
    /// string is unterminated (the caller clamps it to cover the rest of the line).
    private static func closingQuote(_ line: NSString, open: Int, quote: unichar, len: Int) -> Int {
        var j = open + 1
        while j < len {
            let c = line.character(at: j)
            if quote == doubleQuote, c == backslash, j + 1 < len { j += 2; continue }
            if c == quote {
                // YAML single-quoted strings escape a quote by doubling it.
                if quote == singleQuote, j + 1 < len, line.character(at: j + 1) == singleQuote { j += 2; continue }
                return j
            }
            j += 1
        }
        return len
    }

    private static let scalarKeywords: Set<String> = [
        "true", "True", "TRUE", "false", "False", "FALSE",
        "null", "Null", "NULL", "~",
        "yes", "Yes", "YES", "no", "No", "NO",
        "on", "On", "ON", "off", "Off", "OFF",
    ]

    private static func isScalarKeyword(_ word: String) -> Bool {
        scalarKeywords.contains(word)
    }

    private static func isNumber(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        var seenDigit = false
        var seenDot = false
        var seenExp = false
        let chars = Array(word)
        var idx = 0
        if chars[idx] == "+" || chars[idx] == "-" { idx += 1 }
        while idx < chars.count {
            let ch = chars[idx]
            if ch.isNumber {
                seenDigit = true
            } else if ch == "." {
                if seenDot || seenExp { return false }
                seenDot = true
            } else if ch == "e" || ch == "E" {
                if seenExp || !seenDigit { return false }
                seenExp = true
                if idx + 1 < chars.count, chars[idx + 1] == "+" || chars[idx + 1] == "-" { idx += 1 }
            } else {
                return false
            }
            idx += 1
        }
        return seenDigit
    }
}

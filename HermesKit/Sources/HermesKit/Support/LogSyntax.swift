import Foundation

/// Splits a single Hermes log line into ordered, token-tagged segments. Pure
/// and Foundation-only so it can be unit-tested here; the UI maps each token to
/// a color (mirroring the `HermesDoctor.lineStatus` / `DoctorView.color(for:)`
/// split).
///
/// **Fidelity invariant:** `segments(of: line).map(\.text).joined() == line`.
/// Every character of the input — including the spaces and `": "` between
/// fields — lands in exactly one segment, so text selection and "Copy visible"
/// reproduce the original line byte-for-byte. Callers should pass a line with
/// any trailing newline already stripped (the view trims before rendering).
public enum LogSyntax {
    public enum Level: String, Sendable, Equatable {
        case debug, info, warning, error, critical
    }

    public enum Token: Sendable, Equatable {
        case timestamp        // 2026-05-28 22:35:51,312
        case level(Level)     // DEBUG/INFO/WARNING/ERROR/CRITICAL
        case logger           // gateway.platforms.telegram
        case message          // remainder of a standard log line
        case traceFile        //   File "…", line N, in func
        case traceException   // telegram.error.NetworkError: … / Traceback (most recent call last):
        case traceCaret       //         ^^^^^^^^^^
        case separator        // spaces / ": " between fields — keeps concat == input
        case plain            // anything unrecognized
    }

    public struct Segment: Sendable, Equatable {
        public let text: String
        public let token: Token

        public init(text: String, token: Token) {
            self.text = text
            self.token = token
        }
    }

    public static func segments(of line: String) -> [Segment] {
        // Standard Python-logging line: `<ts> LEVEL <dotted.logger>: <message>`.
        // Anchored at the start; the message is taken as the literal remainder
        // after the matched prefix so it preserves any trailing whitespace and
        // can't be mis-split when it happens to contain a level word.
        //
        // Regex is built inline rather than cached in a `static let`: under
        // Swift 6 strict concurrency `Regex` isn't `Sendable`, so it can't be a
        // stored global (same reason `DashboardTokenExtractor` inlines its
        // pattern). Only visible `LazyVStack` rows tokenize, so the cost is
        // bounded.
        // `:[ ]` rather than `: ` because a Swift regex literal may not end
        // with a space (the lexer would treat the trailing `/` as division).
        let standard = /^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3}) (DEBUG|INFO|WARNING|ERROR|CRITICAL) ([\w.]+):[ ]/
        if let match = line.prefixMatch(of: standard),
           let level = Level(rawValue: String(match.output.2).lowercased()) {
            let timestamp = String(match.output.1)
            let levelText = String(match.output.2)
            let logger = String(match.output.3)
            let message = String(line[match.range.upperBound...])
            var segments: [Segment] = [
                Segment(text: timestamp, token: .timestamp),
                Segment(text: " ", token: .separator),
                Segment(text: levelText, token: .level(level)),
                Segment(text: " ", token: .separator),
                Segment(text: logger, token: .logger),
                Segment(text: ": ", token: .separator),
            ]
            if !message.isEmpty {
                segments.append(Segment(text: message, token: .message))
            }
            return segments
        }

        // Traceback file frame: `  File "…", line N[, in func]`.
        if line.prefixMatch(of: /^\s*File ".*", line \d+/) != nil {
            return [Segment(text: line, token: .traceFile)]
        }

        // Caret underline: indentation followed by a run of only `^`.
        let core = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !core.isEmpty, core.allSatisfy({ $0 == "^" }) {
            return [Segment(text: line, token: .traceCaret)]
        }

        // Exception line: the `Traceback` header, or an unindented
        // `Name: message` whose name is dotted or ends in Error/Exception.
        if line.hasPrefix("Traceback (most recent call last):") {
            return [Segment(text: line, token: .traceException)]
        }
        if let first = line.first, !first.isWhitespace,
           let match = line.prefixMatch(of: /([\w.]+):[ ]/) {
            let name = String(match.output.1)
            if name.contains(".") || name.hasSuffix("Error") || name.hasSuffix("Exception") {
                return [Segment(text: line, token: .traceException)]
            }
        }

        // Fallback: the whole line is one plain segment (covers empty and
        // whitespace-only lines too — both still satisfy the fidelity invariant).
        return [Segment(text: line, token: .plain)]
    }
}

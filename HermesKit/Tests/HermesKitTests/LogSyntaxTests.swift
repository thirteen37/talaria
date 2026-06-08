import Foundation
import Testing
@testable import HermesKit

@Suite
struct LogSyntaxTests {
    // MARK: - Standard log lines per level

    @Test
    func tokenizesInfoLine() {
        let line = "2026-05-28 22:35:51,321 INFO telegram.ext.Application: Application is stopping."
        let segs = LogSyntax.segments(of: line)
        #expect(segs.map(\.token) == [
            .timestamp,
            .separator,
            .level(.info),
            .separator,
            .logger,
            .separator,
            .message,
        ])
        #expect(segs[0].text == "2026-05-28 22:35:51,321")
        #expect(segs[2].text == "INFO")
        #expect(segs[4].text == "telegram.ext.Application")
        #expect(segs[6].text == "Application is stopping.")
    }

    @Test
    func tokenizesEachLevel() {
        let cases: [(String, LogSyntax.Level)] = [
            ("DEBUG", .debug),
            ("INFO", .info),
            ("WARNING", .warning),
            ("ERROR", .error),
            ("CRITICAL", .critical),
        ]
        for (raw, level) in cases {
            let line = "2026-05-28 22:35:51,312 \(raw) gateway.run: a message"
            let segs = LogSyntax.segments(of: line)
            let levelSeg = segs.first { if case .level = $0.token { return true } else { return false } }
            #expect(levelSeg?.token == .level(level))
            #expect(levelSeg?.text == raw)
        }
    }

    // MARK: - Fidelity invariant

    @Test
    func concatenationEqualsInputForRepresentativeLines() {
        let lines = [
            "2026-05-28 22:35:51,312 WARNING gateway.platforms.telegram: [Telegram] reconnect failed",
            "2026-05-28 22:46:00,808 INFO gateway.run: ✓ telegram reconnected successfully",
            "  File \"/Users/hermes/.hermes/hermes-agent/venv/lib/python3.11/site-packages/httpx/_client.py\", line 1730, in _send_single_request",
            "               ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^",
            "telegram.error.NetworkError: httpx.ConnectError: All connection attempts failed",
            "Traceback (most recent call last):",
            "    raise last_error",
            "",
            "   \t ",
        ]
        for line in lines {
            let joined = LogSyntax.segments(of: line).map(\.text).joined()
            #expect(joined == line, "fidelity broken for: \(line.debugDescription)")
        }
    }

    @Test
    func concatenationEqualsInputForLogsFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/Dashboard/logs", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let payload = try JSONDecoder().decode(LogsFixture.self, from: data)
        #expect(!payload.lines.isEmpty)
        for raw in payload.lines {
            // The view trims trailing newlines before tokenizing; mirror that.
            let line = raw.trimmingCharacters(in: .newlines)
            let joined = LogSyntax.segments(of: line).map(\.text).joined()
            #expect(joined == line, "fidelity broken for fixture line: \(line.debugDescription)")
        }
    }

    private struct LogsFixture: Decodable {
        let lines: [String]
    }

    // MARK: - Traceback lines

    @Test
    func classifiesTracebackFileLine() {
        let line = "  File \"/Users/hermes/app/_client.py\", line 1730, in _send_single_request"
        let segs = LogSyntax.segments(of: line)
        #expect(segs.count == 1)
        #expect(segs[0].token == .traceFile)
        #expect(segs[0].text == line)
    }

    @Test
    func classifiesFileLineWithoutInClause() {
        let line = "  File \"contextlib.py\", line 158"
        let segs = LogSyntax.segments(of: line)
        #expect(segs.count == 1)
        #expect(segs[0].token == .traceFile)
    }

    @Test
    func classifiesCaretLine() {
        let line = "               ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^"
        let segs = LogSyntax.segments(of: line)
        #expect(segs.count == 1)
        #expect(segs[0].token == .traceCaret)
        #expect(segs[0].text == line)
    }

    @Test
    func classifiesExceptionLineWithDottedName() {
        let line = "telegram.error.NetworkError: httpx.ConnectError: All connection attempts failed"
        let segs = LogSyntax.segments(of: line)
        #expect(segs.count == 1)
        #expect(segs[0].token == .traceException)
    }

    @Test
    func classifiesExceptionLineEndingInError() {
        let line = "ValueError: bad input"
        let segs = LogSyntax.segments(of: line)
        #expect(segs.count == 1)
        #expect(segs[0].token == .traceException)
    }

    @Test
    func classifiesTracebackHeader() {
        let line = "Traceback (most recent call last):"
        let segs = LogSyntax.segments(of: line)
        #expect(segs.count == 1)
        #expect(segs[0].token == .traceException)
    }

    // MARK: - Plain / fallback

    @Test
    func plainForLineWithoutTimestamp() {
        let line = "    raise last_error"
        let segs = LogSyntax.segments(of: line)
        #expect(segs.count == 1)
        #expect(segs[0].token == .plain)
        #expect(segs[0].text == line)
    }

    @Test
    func plainForEmptyString() {
        let segs = LogSyntax.segments(of: "")
        #expect(segs.map(\.text).joined() == "")
        #expect(segs.allSatisfy { $0.token == .plain })
    }

    @Test
    func plainForWhitespaceOnlyLine() {
        let line = "   \t "
        let segs = LogSyntax.segments(of: line)
        #expect(segs.count == 1)
        #expect(segs[0].token == .plain)
        #expect(segs[0].text == line)
    }

    // MARK: - Edge cases

    @Test
    func messageContainingLevelWordIsNotMisclassified() {
        // The word ERROR appears in the message, but the level field is INFO.
        let line = "2026-05-28 22:35:51,319 INFO gateway.run: an ERROR occurred downstream"
        let segs = LogSyntax.segments(of: line)
        let levelSeg = segs.first(where: { if case .level = $0.token { return true } else { return false } })
        #expect(levelSeg?.token == .level(.info))
        let messageSeg = segs.first(where: { $0.token == .message })
        #expect(messageSeg?.text == "an ERROR occurred downstream")
    }
}

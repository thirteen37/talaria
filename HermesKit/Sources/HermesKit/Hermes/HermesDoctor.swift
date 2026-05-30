import Foundation

public struct DoctorReport: Sendable, Equatable {
    public struct Section: Sendable, Equatable, Identifiable {
        public let id: Int
        public let title: String
        public let body: String

        public init(id: Int, title: String, body: String) {
            self.id = id
            self.title = title
            self.body = body
        }
    }

    public let raw: String
    public let sections: [Section]
    public let exitCode: Int32
    /// Whether the report's raw text advertised the `doctor --fix` self-repair
    /// flag (the "Tip: run 'hermes doctor --fix' …" line). Drives the UI's
    /// optional **Run Fixes** affordance.
    public let suggestsFix: Bool

    public init(raw: String, sections: [Section], exitCode: Int32, suggestsFix: Bool = false) {
        self.raw = raw
        self.sections = sections
        self.exitCode = exitCode
        self.suggestsFix = suggestsFix
    }
}

/// Classification of a doctor body line by its leading status glyph. The UI
/// maps each case to a color; keeping the classification here keeps it pure,
/// Foundation-only, and testable.
public enum DoctorLineStatus: Sendable, Equatable {
    case ok       // ✓
    case warning  // ⚠
    case failure  // ✗ / ✖
    case hint     // →
    case plain    // anything else
}

public enum HermesDoctorError: Error, Equatable, Sendable, LocalizedError {
    case commandFailed(exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "hermes doctor failed (exit \(code))" : trimmed
        }
    }
}

public enum HermesDoctor {
    public static func run(runner: HermesAdminRunning) async throws -> DoctorReport {
        try await report(from: ["doctor"], runner: runner)
    }

    /// Runs `hermes doctor --fix` and parses its output the same way `run`
    /// does. Use only when a prior report's `suggestsFix` is true.
    public static func runFix(runner: HermesAdminRunning) async throws -> DoctorReport {
        try await report(from: ["doctor", "--fix"], runner: runner)
    }

    /// True when doctor's output advertises its self-repair flag, e.g.
    /// "Tip: run 'hermes doctor --fix' to auto-fix what's possible."
    /// Matched on the `doctor --fix` substring so wording tweaks upstream
    /// (different tip phrasing, quoting) still trigger the offer.
    public static func suggestsFix(_ text: String) -> Bool {
        text.contains("doctor --fix")
    }

    /// Classifies a body line by its leading status glyph (after trimming
    /// leading whitespace). Pure; the UI maps the result to a color.
    public static func lineStatus(_ line: String) -> DoctorLineStatus {
        let scalars = line.drop(while: { $0 == " " || $0 == "\t" }).unicodeScalars
        guard let first = scalars.first else { return .plain }
        switch first.value {
        case 0x2713: return .ok               // ✓
        case 0x26A0: return .warning          // ⚠
        case 0x2717, 0x2716: return .failure  // ✗ ✖
        case 0x2192: return .hint             // →
        default: return .plain
        }
    }

    private static func report(from arguments: [String], runner: HermesAdminRunning) async throws -> DoctorReport {
        let result = try await runner.run(HermesAdminCommand(arguments: arguments))
        // Doctor traditionally returns a non-zero exit when it surfaces
        // problems, but the text body is still useful. Only treat empty
        // output + non-zero as a hard failure.
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode != 0, trimmed.isEmpty {
            throw HermesDoctorError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        return DoctorReport(
            raw: result.stdout,
            sections: parseSections(result.stdout),
            exitCode: result.exitCode,
            suggestsFix: suggestsFix(result.stdout)
        )
    }

    /// Best-effort section splitter. Section heuristics (any of):
    ///   * `◆ Title` — the Rich diamond used by real `hermes doctor`. We
    ///     deliberately don't accept `+`/`*` as alternative bullets: any
    ///     future doctor output that includes a markdown bullet list inside
    ///     a section body (`* config-key: value`) would otherwise be
    ///     mis-split into one section per item. If a future hermes build
    ///     emits a different bullet for headers, add it here under the same
    ///     "leading glyph is structurally a header, never a list item" rule.
    ///   * `== Title ==` markdown-style headers
    ///   * `--- Title ---` separators
    ///   * Blank line followed by an `ALL CAPS:` or `Title-Cased:` line
    /// Anything before the first header lands in a synthetic "Summary" section.
    public static func parseSections(_ text: String) -> [DoctorReport.Section] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var sections: [DoctorReport.Section] = []
        var currentTitle: String? = nil
        var currentLines: [String] = []
        var sawAnyHeader = false

        func flush() {
            guard !currentLines.isEmpty || currentTitle != nil else { return }
            let body = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty, currentTitle == nil { return }
            sections.append(DoctorReport.Section(
                id: sections.count,
                title: currentTitle ?? "Summary",
                body: body
            ))
        }

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Drop the box-drawing banner Hermes prints at the top
            // (`┌──┐`, `│ 🩺 Hermes Doctor │`, `└──┘`). It looks like a
            // section but contains no content — keeping it would surface as
            // a confusing single-line "🩺 Hermes Doctor" section.
            if isBoxDrawingNoise(trimmed) { continue }
            if let header = matchHeader(trimmed) {
                flush()
                currentTitle = header
                currentLines = []
                sawAnyHeader = true
                continue
            }
            // ALL CAPS standalone line after a blank line counts as a header.
            if isStandaloneCapsHeader(trimmed, previous: index > 0 ? lines[index - 1] : nil) {
                flush()
                currentTitle = trimmed
                currentLines = []
                sawAnyHeader = true
                continue
            }
            currentLines.append(line)
        }
        flush()

        // If nothing matched, return a single "Report" section with the whole body.
        if !sawAnyHeader, sections.count == 1 {
            return [DoctorReport.Section(id: 0, title: "Report", body: sections[0].body)]
        }
        // Strip the synthetic pre-header "Summary" *only* when its body
        // looks like banner chrome (no alphanumeric content survives once
        // box-drawing and decorative glyphs are stripped). Legitimate
        // preamble like "Some preamble" before the first real header
        // should still surface — see HermesDoctorTests.
        if sawAnyHeader,
           let first = sections.first,
           first.title == "Summary",
           isDecorativeBody(first.body) {
            sections.removeFirst()
            sections = sections.enumerated().map { idx, s in
                DoctorReport.Section(id: idx, title: s.title, body: s.body)
            }
        }
        return sections
    }

    /// A body is considered decorative if removing box-drawing glyphs and
    /// whitespace leaves only the banner phrase (or nothing). Used to
    /// distinguish "🩺 Hermes Doctor" banner pre-header garbage from real
    /// pre-header content the user might still want to see.
    private static func isDecorativeBody(_ body: String) -> Bool {
        let stripped = body.unicodeScalars.filter { scalar in
            // Strip box-drawing range.
            if scalar.value >= 0x2500 && scalar.value <= 0x257F { return false }
            // Strip whitespace.
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
            return true
        }
        let text = String(String.UnicodeScalarView(stripped))
        if text.isEmpty { return true }
        // Tolerate the standard banner phrase plus its emoji.
        let normalized = text
            .replacingOccurrences(of: "🩺", with: "")
            .lowercased()
        return normalized == "hermesdoctor"
    }

    private static func matchHeader(_ line: String) -> String? {
        // ◆ Title — Rich's diamond bullet, what real hermes uses. Restricted
        // to this single glyph on purpose; see the `parseSections` doc
        // comment for the false-positive trap with `+`/`*`.
        if let first = line.unicodeScalars.first, first == "\u{25C6}" {
            let rest = String(line.unicodeScalars.dropFirst())
            let title = rest.trimmingCharacters(in: .whitespaces)
            if !title.isEmpty, title.count <= 80 {
                return title
            }
        }
        // == Title == or === Title ===
        if line.hasPrefix("=="), line.hasSuffix("==") {
            let inner = line.drop(while: { $0 == "=" }).reversed().drop(while: { $0 == "=" }).reversed()
            let title = String(inner).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        // --- Title ---
        if line.hasPrefix("---"), line.hasSuffix("---") {
            let inner = line.drop(while: { $0 == "-" }).reversed().drop(while: { $0 == "-" }).reversed()
            let title = String(inner).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return nil
    }

    /// Lines made entirely of Rich box-drawing chars (and whitespace) are
    /// decorative chrome around the banner — `┌─┐`, `└─┘`, the long
    /// `────` summary divider. Strip them so they don't clutter a section
    /// body or get mistaken for content.
    private static func isBoxDrawingNoise(_ line: String) -> Bool {
        if line.isEmpty { return false }
        return line.unicodeScalars.allSatisfy { scalar in
            // U+2500..U+257F is the Box Drawing block; the `│` content rows
            // would normally trip this but the banner only contains `─` and
            // corners, no text. Banner lines that contain text like
            // `│ 🩺 Hermes Doctor │` fail this all-satisfy check because of
            // the emoji + letters, so they fall through and get treated as
            // regular body content — which is fine since they sit before
            // the first `◆` header and merge into the (eventually-flushed)
            // pre-header buffer that the "Summary" fallback discards.
            (scalar.value >= 0x2500 && scalar.value <= 0x257F) ||
                scalar == " " || scalar == "\t"
        }
    }

    private static func isStandaloneCapsHeader(_ line: String, previous: String?) -> Bool {
        guard !line.isEmpty, line.count <= 60 else { return false }
        let blankPrev = previous.map { $0.trimmingCharacters(in: .whitespaces).isEmpty } ?? true
        guard blankPrev else { return false }
        let letters = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let allUpper = letters.allSatisfy {
            CharacterSet.uppercaseLetters.contains($0) || !CharacterSet.lowercaseLetters.contains($0)
        }
        return allUpper
    }
}

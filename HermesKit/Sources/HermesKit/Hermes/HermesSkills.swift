import Foundation

public struct SkillRow: Equatable, Sendable, Identifiable {
    public let name: String
    public let enabled: Bool
    /// Display-friendly secondary label (category, or source when category is
    /// empty). Surfaces in the "Path" column.
    public let path: String?
    /// Registry source bucket (`builtin`, `local`, `hub`, …). Required for
    /// `hermes skills inspect` on builtins, whose bare names don't resolve in
    /// the registry's fuzzy lookup — `inspect dogfood` returns "no exact
    /// match", but `inspect builtin/dogfood` returns the skill body. Nil for
    /// non-Rich-format parses where we don't have the column.
    public let source: String?

    public var id: String { name }

    public init(name: String, enabled: Bool, path: String? = nil, source: String? = nil) {
        self.name = name
        self.enabled = enabled
        self.path = path
        self.source = source
    }
}

public enum HermesSkillsError: Error, Equatable, Sendable, LocalizedError {
    case commandUnavailable(String)
    case commandFailed(exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .commandUnavailable(let detail):
            return "Skills command unavailable in this Hermes version: \(detail)"
        case .commandFailed(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "hermes skills failed (exit \(code))" : trimmed
        }
    }
}

public enum HermesSkills {
    public static func list(runner: HermesAdminRunning) async throws -> [SkillRow] {
        let result = try await runner.run(HermesAdminCommand(arguments: ["skills", "list"]))
        try ensureSuccess(result)
        return parse(result.stdout)
    }

    public static func enable(runner: HermesAdminRunning, name: String) async throws {
        let result = try await runner.run(HermesAdminCommand(arguments: ["skills", "enable", "--", name]))
        try ensureSuccess(result)
    }

    public static func disable(runner: HermesAdminRunning, name: String) async throws {
        let result = try await runner.run(HermesAdminCommand(arguments: ["skills", "disable", "--", name]))
        try ensureSuccess(result)
    }

    public static func show(runner: HermesAdminRunning, name: String, source: String? = nil) async throws -> String {
        // Hermes calls this `inspect`. For builtin/local skills the bare name
        // doesn't resolve in the registry's fuzzy lookup ("No exact match for
        // 'dogfood'. Did you mean…"), so when we know the source we prefix it
        // — `inspect builtin/dogfood` returns the actual skill.
        let identifier = (source.flatMap { $0.isEmpty ? nil : $0 }).map { "\($0)/\(name)" } ?? name
        let inspect = try await runner.run(HermesAdminCommand(arguments: ["skills", "inspect", "--", identifier]))
        if inspect.exitCode == 0 {
            return stripBoxDrawingWrap(inspect.stdout)
        }
        // Older builds may have used `show`; fall back so the preview works
        // across hermes versions.
        let lowered = inspect.stderr.lowercased()
        if lowered.contains("invalid choice") || lowered.contains("no such command") || lowered.contains("unknown command") {
            let result = try await runner.run(HermesAdminCommand(arguments: ["skills", "show", "--", name]))
            try ensureSuccess(result)
            return result.stdout
        }
        try ensureSuccess(inspect)
        return stripBoxDrawingWrap(inspect.stdout)
    }

    /// Strips the `│ … │` box-drawing wrapping that `hermes skills inspect`
    /// applies. Each body line is `│ <pad><content><pad> │`; the cleaner
    /// removes the verticals, trims the trailing pad, and drops border-only
    /// rows so MarkdownText receives unwrapped content.
    static func stripBoxDrawingWrap(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if isBoxBorderLine(line) { continue }
            if let stripped = stripBorderedRow(line) {
                lines.append(stripped)
            } else {
                lines.append(line)
            }
        }
        // Tighten consecutive blank lines so the stripped body doesn't have
        // double spacing where padding rows used to sit.
        var collapsed: [String] = []
        var lastBlank = false
        for line in lines {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank && lastBlank { continue }
            collapsed.append(line)
            lastBlank = isBlank
        }
        return collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isBoxBorderLine(_ line: String) -> Bool {
        let stripped = line.trimmingCharacters(in: .whitespaces)
        if stripped.isEmpty { return false }
        // Top/bottom panel rows have curly corners (╭╮╰╯) and may contain
        // a centered title — `╭─── Skill: Dogfood ───╮` and the footer
        // hint `╰─── hermes skills install <id> to install ───╯`. The
        // title text is presentation chrome; dropping the whole row is
        // the right call.
        if stripped.contains("╭") || stripped.contains("╮")
            || stripped.contains("╰") || stripped.contains("╯") {
            return true
        }
        return stripped.unicodeScalars.allSatisfy { scalar in
            // Pure box-drawing separators (`├──┤`, `─` divider lines).
            (scalar.value >= 0x2500 && scalar.value <= 0x257F) || scalar == " " || scalar == "\t"
        }
    }

    private static func stripBorderedRow(_ line: String) -> String? {
        // Match `│ … │` (or whatever vertical hermes used). The trailing
        // border is right-aligned to the box width, so the right `│` is
        // preceded by padding spaces we want to drop along with the
        // separator itself.
        guard line.contains("│") else { return nil }
        guard let firstBar = line.firstIndex(of: "│") else { return nil }
        // Anything before the first `│` is left-margin padding from Rich's
        // panel renderer — ignore it.
        var rest = line[line.index(after: firstBar)...]
        if let lastBar = rest.lastIndex(of: "│") {
            rest = rest[rest.startIndex..<lastBar]
        }
        let body = String(rest)
        // Rich pads each row to box width with trailing spaces; trim them
        // so multi-line content doesn't have weird hanging whitespace.
        return body.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    /// Tolerant parser. Supported row shapes:
    ///   * Rich box-drawing tables (`┃ Name ┃ Category ┃ ... ┃ Status ┃`) —
    ///     what real hermes builds emit. Header row drives column mapping;
    ///     status `enabled`/`disabled` determines the toggle; category lands
    ///     in `path` so it surfaces in the existing column.
    ///   * `[x] name optional/path`   `[ ] name`
    ///   * `name  enabled  optional/path`  (enabled is yes/no/true/false/on/off/1/0)
    ///   * `* name` / `name`             (treated as enabled, no path)
    public static func parse(_ text: String) -> [SkillRow] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.contains(where: { $0.contains("│") || $0.contains("┃") }) {
            return parseRichTable(lines: lines)
        }
        var rows: [SkillRow] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if isHeaderLine(line) { continue }
            if let parsed = parseLine(line) {
                rows.append(parsed)
            }
        }
        return rows
    }

    /// Parses Rich's box-drawing table layout (the real `hermes skills list`
    /// output). The format is:
    /// ```
    /// ┏━━━━┳━━━━┓        ← top border (no │/┃, ignored)
    /// ┃ Name ┃ Status ┃  ← header row
    /// ┡━━━━╇━━━━┩       ← header→body separator (no │/┃, ignored)
    /// │ foo │ enabled │ ← data row
    /// └────┴────┘       ← bottom border (no │/┃, ignored)
    /// ```
    /// Border-only rows are filtered upstream because none contain a vertical
    /// cell separator. The first row with cell content is treated as the
    /// header; subsequent rows are mapped through it. Anything outside the
    /// table (title banners, footer summaries) is harmless because it lacks
    /// the vertical separators.
    private static func parseRichTable(lines: [String]) -> [SkillRow] {
        var rows: [SkillRow] = []
        var columnMap: [String: Int] = [:]
        for raw in lines {
            if !raw.contains("│") && !raw.contains("┃") { continue }
            let cells = splitRichCells(raw)
            if cells.isEmpty { continue }
            if cells.allSatisfy({ $0.isEmpty }) { continue }
            if columnMap.isEmpty {
                for (idx, cell) in cells.enumerated() {
                    columnMap[cell.lowercased()] = idx
                }
                continue
            }
            let nameIdx = columnMap["name"] ?? 0
            guard nameIdx < cells.count else { continue }
            let name = cells[nameIdx]
            if name.isEmpty { continue }
            let statusCell = columnMap["status"].flatMap { $0 < cells.count ? cells[$0] : nil }
            let enabled = statusCell.flatMap(parseBool) ?? true
            // Prefer category; fall back to source when category is empty,
            // so single-category-bucket builds (most third-party skills are
            // empty-category builtins) still surface useful provenance.
            let categoryCell = columnMap["category"].flatMap { $0 < cells.count ? cells[$0] : nil }
            let sourceCell = columnMap["source"].flatMap { $0 < cells.count ? cells[$0] : nil }
            let secondary = [categoryCell, sourceCell]
                .compactMap { $0 }
                .first(where: { !$0.isEmpty })
            let sourceValue = sourceCell.flatMap { $0.isEmpty ? nil : $0 }
            rows.append(SkillRow(name: name, enabled: enabled, path: secondary, source: sourceValue))
        }
        return rows
    }

    /// Splits a Rich table row on either light (`│`) or heavy (`┃`) verticals
    /// and trims each cell. Empty cells (from the leading/trailing edge
    /// separators) are dropped — those are the artifacts of the box edges,
    /// not data values.
    static func splitRichCells(_ line: String) -> [String] {
        let parts = line.split(whereSeparator: { $0 == "│" || $0 == "┃" })
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseLine(_ line: String) -> SkillRow? {
        // [x] name path
        if line.hasPrefix("[") {
            let scanner = Scanner(string: line)
            scanner.charactersToBeSkipped = nil
            guard scanner.scanString("[") != nil,
                  let mark = scanner.scanUpToString("]"),
                  scanner.scanString("]") != nil else {
                return nil
            }
            let enabled = mark.trimmingCharacters(in: .whitespaces).lowercased() == "x"
            let remainder = String(line[scanner.currentIndex...]).trimmingCharacters(in: .whitespaces)
            let parts = splitFields(remainder)
            guard let name = parts.first else { return nil }
            let path = parts.count >= 2 ? parts[1...].joined(separator: " ") : nil
            return SkillRow(name: name, enabled: enabled, path: path)
        }

        let fields = splitFields(line)
        guard let first = fields.first else { return nil }
        if first == "*" {
            guard fields.count >= 2 else { return nil }
            return SkillRow(name: fields[1], enabled: true, path: fields.count >= 3 ? fields[2...].joined(separator: " ") : nil)
        }
        // name [enabled] [path...]
        if fields.count >= 2, let flag = parseBool(fields[1]) {
            let path = fields.count >= 3 ? fields[2...].joined(separator: " ") : nil
            return SkillRow(name: first, enabled: flag, path: path)
        }
        return SkillRow(name: first, enabled: true, path: fields.count >= 2 ? fields[1...].joined(separator: " ") : nil)
    }

    static func splitFields(_ line: String) -> [String] {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "yes", "y", "true", "on", "1", "enabled":
            return true
        case "no", "n", "false", "off", "0", "disabled":
            return false
        default:
            return nil
        }
    }

    static func isHeaderLine(_ line: String) -> Bool {
        // ASCII separator rules (---- ====) or column headers.
        let stripped = line.replacingOccurrences(of: " ", with: "")
        if stripped.allSatisfy({ $0 == "-" || $0 == "=" || $0 == "_" }), !stripped.isEmpty {
            return true
        }
        let lowered = line.lowercased()
        // Header row: starts with "name" + has "enabled" somewhere — best-effort.
        if lowered.hasPrefix("name") && lowered.contains("enabled") {
            return true
        }
        return false
    }

    static func ensureSuccess(_ result: HermesAdminResult) throws {
        guard result.exitCode != 0 else { return }
        let stderr = result.stderr.lowercased()
        // Tightened from a bare `"no such"` so we don't swallow `env: hermes:
        // No such file or directory` and mislabel a PATH failure as "version
        // too old".
        if stderr.contains("unknown command")
            || stderr.contains("no such command")
            || stderr.contains("no such subcommand") {
            throw HermesSkillsError.commandUnavailable(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        throw HermesSkillsError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
    }
}

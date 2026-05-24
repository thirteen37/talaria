import Foundation

public struct ToolRow: Equatable, Sendable, Identifiable {
    public let name: String
    public let platform: String?
    public let enabled: Bool

    public var id: String { name }

    public init(name: String, platform: String?, enabled: Bool) {
        self.name = name
        self.platform = platform
        self.enabled = enabled
    }
}

public enum HermesToolsError: Error, Equatable, Sendable, LocalizedError {
    case commandUnavailable(String)
    case commandFailed(exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .commandUnavailable(let detail):
            return "Tools command unavailable in this Hermes version: \(detail)"
        case .commandFailed(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "hermes tools failed (exit \(code))" : trimmed
        }
    }
}

public enum HermesTools {
    public static func list(runner: HermesAdminRunning) async throws -> [ToolRow] {
        let result = try await runner.run(HermesAdminCommand(arguments: ["tools", "list"]))
        try ensureSuccess(result)
        return parse(result.stdout)
    }

    public static func enable(runner: HermesAdminRunning, name: String) async throws {
        let result = try await runner.run(HermesAdminCommand(arguments: ["tools", "enable", "--", name]))
        try ensureSuccess(result)
    }

    public static func disable(runner: HermesAdminRunning, name: String) async throws {
        let result = try await runner.run(HermesAdminCommand(arguments: ["tools", "disable", "--", name]))
        try ensureSuccess(result)
    }

    /// Tolerant parser. Supported row shapes (per line):
    ///   * `  ✓ enabled  name  emoji description` — real hermes output;
    ///     ✓/✗ is the canonical toggle, the word "enabled"/"disabled" that
    ///     follows it is redundant and dropped to avoid being mistaken for
    ///     the name.
    ///   * `[x] name platform`
    ///   * `name platform enabled`
    ///   * `name enabled`
    ///   * `name`
    public static func parse(_ text: String) -> [ToolRow] {
        var rows: [ToolRow] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if isHeaderLine(line) { continue }
            if isCategoryHeader(line) { continue }
            if let row = parseLine(line) { rows.append(row) }
        }
        return rows
    }

    /// `Built-in toolsets (cli):` and similar group banners precede the
    /// rows. They end in a colon and don't contain the ✓/✗ bullet, so
    /// distinguishing them from data rows is cheap.
    private static func isCategoryHeader(_ line: String) -> Bool {
        guard line.hasSuffix(":") else { return false }
        return !line.contains("✓") && !line.contains("✗")
    }

    private static func parseLine(_ line: String) -> ToolRow? {
        // Bullet form: `✓ enabled  name  emoji description` (real hermes).
        if let bulletChar = line.unicodeScalars.first,
           bulletChar == "\u{2713}" || bulletChar == "\u{2717}" {
            let enabled = bulletChar == "\u{2713}"
            let remainder = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            // Split on runs of 2+ spaces so the trailing "🔍 Web Search &
            // Scraping" stays a single field — `HermesCron.splitFields` does
            // exactly this rather than the whitespace-greedy split that the
            // existing `HermesSkills.splitFields` performs.
            var fields = HermesCron.splitFields(remainder)
            // Drop the redundant "enabled"/"disabled" word. Hermes always
            // emits it after the bullet, so without this the name column
            // would consistently read "enabled" for every row.
            if let head = fields.first?.lowercased(),
               head == "enabled" || head == "disabled" {
                fields.removeFirst()
            }
            guard let name = fields.first, !name.isEmpty else { return nil }
            let platform: String? = fields.count >= 2
                ? fields[1...].joined(separator: " ")
                : nil
            return ToolRow(name: name, platform: platform, enabled: enabled)
        }
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
            let parts = HermesSkills.splitFields(remainder)
            guard let name = parts.first else { return nil }
            let platform = parts.count >= 2 ? parts[1...].joined(separator: " ") : nil
            return ToolRow(name: name, platform: platform, enabled: enabled)
        }
        let parts = HermesSkills.splitFields(line)
        guard let name = parts.first else { return nil }
        if parts.count == 1 {
            return ToolRow(name: name, platform: nil, enabled: true)
        }
        // Try: name <enabled>
        if parts.count == 2, let flag = HermesSkills.parseBool(parts[1]) {
            return ToolRow(name: name, platform: nil, enabled: flag)
        }
        // Try: name platform enabled
        if parts.count >= 3, let flag = HermesSkills.parseBool(parts[parts.count - 1]) {
            let platform = parts[1..<(parts.count - 1)].joined(separator: " ")
            return ToolRow(name: name, platform: platform, enabled: flag)
        }
        // Fall back: name platform... (assume enabled)
        let platform = parts[1...].joined(separator: " ")
        return ToolRow(name: name, platform: platform, enabled: true)
    }

    static func isHeaderLine(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        if stripped.allSatisfy({ $0 == "-" || $0 == "=" || $0 == "_" }), !stripped.isEmpty {
            return true
        }
        let lowered = line.lowercased()
        if lowered.hasPrefix("name") && (lowered.contains("enabled") || lowered.contains("platform")) {
            return true
        }
        return false
    }

    static func ensureSuccess(_ result: HermesAdminResult) throws {
        guard result.exitCode != 0 else { return }
        let stderr = result.stderr.lowercased()
        // Match argparse/Click-style "command not in this hermes" phrasings but
        // not `env: hermes: No such file or directory` — the bare `"no such"`
        // substring used to swallow that, surfacing it as "version too old".
        if stderr.contains("unknown command")
            || stderr.contains("no such command")
            || stderr.contains("no such subcommand") {
            throw HermesToolsError.commandUnavailable(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        throw HermesToolsError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
    }
}

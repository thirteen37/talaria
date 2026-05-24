import Foundation

public struct SkillRow: Equatable, Sendable, Identifiable {
    public let name: String
    public let enabled: Bool
    public let path: String?

    public var id: String { name }

    public init(name: String, enabled: Bool, path: String? = nil) {
        self.name = name
        self.enabled = enabled
        self.path = path
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

    public static func show(runner: HermesAdminRunning, name: String) async throws -> String {
        let result = try await runner.run(HermesAdminCommand(arguments: ["skills", "show", "--", name]))
        try ensureSuccess(result)
        return result.stdout
    }

    /// Tolerant parser. Supported row shapes (one per line, header lines and
    /// blank lines ignored):
    ///   * `[x] name optional/path`   `[ ] name`
    ///   * `name  enabled  optional/path`  (enabled is yes/no/true/false/on/off/1/0)
    ///   * `* name` / `name`             (treated as enabled, no path)
    public static func parse(_ text: String) -> [SkillRow] {
        var rows: [SkillRow] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if isHeaderLine(line) { continue }
            if let parsed = parseLine(line) {
                rows.append(parsed)
            }
        }
        return rows
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
        if stderr.contains("unknown command") || stderr.contains("no such") {
            throw HermesSkillsError.commandUnavailable(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        throw HermesSkillsError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
    }
}

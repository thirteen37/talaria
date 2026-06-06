import Foundation

public struct ToolRow: Equatable, Sendable, Identifiable {
    public let name: String
    /// Display text emitted after the tool name in `hermes tools list`.
    /// Historically named `platform`, but for bullet-format Hermes output this
    /// is the emoji + description label, not a gateway platform id.
    public let platform: String?
    public let enabled: Bool

    public var id: String { name }

    public init(name: String, platform: String?, enabled: Bool) {
        self.name = name
        self.platform = platform
        self.enabled = enabled
    }
}

public struct ToolsMatrix: Equatable, Sendable {
    public let platforms: [String]
    public let rows: [Row]

    public init(platforms: [String], rows: [Row]) {
        self.platforms = platforms
        self.rows = rows
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public let name: String
        public let label: String?
        public let enabledByPlatform: [String: Bool]

        public var id: String { name }

        public init(name: String, label: String?, enabledByPlatform: [String: Bool]) {
            self.name = name
            self.label = label
            self.enabledByPlatform = enabledByPlatform
        }
    }

    /// Returns a copy with only `platform`'s column replaced by a freshly listed
    /// `rows`, leaving every other column untouched. Used after a single-cell
    /// toggle so just the affected platform is re-listed — toggling a tool on one
    /// platform can't change another's state, so a full fan-out re-list (one
    /// `tools list` per column plus a `/api/status` call) is wasteful, especially
    /// over remote SSH.
    ///
    /// Tools present in `rows` update their `enabledByPlatform[platform]`; tools
    /// no longer reported for that platform have the key removed (unknown); tools
    /// new to that platform are appended (with only this column known). Existing
    /// row order is preserved so the UI doesn't reshuffle on a toggle.
    public func replacingColumn(_ platform: String, with rows: [ToolRow]) -> ToolsMatrix {
        var freshEnabled: [String: Bool] = [:]
        var freshLabel: [String: String] = [:]
        var freshOrder: [String] = []
        for row in rows {
            if freshEnabled[row.name] == nil { freshOrder.append(row.name) }
            freshEnabled[row.name] = row.enabled
            if freshLabel[row.name] == nil, let label = row.platform { freshLabel[row.name] = label }
        }

        var seen: Set<String> = []
        var updated: [Row] = self.rows.map { row in
            seen.insert(row.name)
            var byPlatform = row.enabledByPlatform
            byPlatform[platform] = freshEnabled[row.name]   // nil clears (unknown)
            return Row(
                name: row.name,
                label: row.label ?? freshLabel[row.name],
                enabledByPlatform: byPlatform
            )
        }
        for name in freshOrder where !seen.contains(name) {
            updated.append(Row(
                name: name,
                label: freshLabel[name],
                enabledByPlatform: [platform: freshEnabled[name] ?? false]
            ))
        }
        return ToolsMatrix(platforms: platforms, rows: updated)
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
    public static func list(runner: HermesAdminRunning, platform: String? = nil) async throws -> [ToolRow] {
        let result = try await runner.run(HermesAdminCommand(arguments: ["tools", "list"] + platformArgs(platform)))
        try ensureSuccess(result)
        return parse(result.stdout)
    }

    public static func enable(runner: HermesAdminRunning, name: String, platform: String? = nil) async throws {
        let result = try await runner.run(
            HermesAdminCommand(arguments: ["tools", "enable"] + platformArgs(platform) + ["--", name])
        )
        try ensureSuccess(result)
    }

    public static func disable(runner: HermesAdminRunning, name: String, platform: String? = nil) async throws {
        let result = try await runner.run(
            HermesAdminCommand(arguments: ["tools", "disable"] + platformArgs(platform) + ["--", name])
        )
        try ensureSuccess(result)
    }

    public static func makeMatrix(platforms: [String], byPlatform: [String: [ToolRow]]) -> ToolsMatrix {
        var rowOrder: [String] = []
        var labels: [String: String] = [:]
        var enabledByTool: [String: [String: Bool]] = [:]

        for platform in platforms {
            guard let rows = byPlatform[platform] else { continue }
            for row in rows {
                if enabledByTool[row.name] == nil {
                    rowOrder.append(row.name)
                    enabledByTool[row.name] = [:]
                }
                if labels[row.name] == nil, let label = row.platform {
                    labels[row.name] = label
                }
                enabledByTool[row.name]?[platform] = row.enabled
            }
        }

        let matrixRows = rowOrder.map { name in
            ToolsMatrix.Row(
                name: name,
                label: labels[name],
                enabledByPlatform: enabledByTool[name] ?? [:]
            )
        }
        return ToolsMatrix(platforms: platforms, rows: matrixRows)
    }

    public static func loadMatrix(runner: HermesAdminRunning, platforms: [String]) async throws -> ToolsMatrix {
        guard !platforms.isEmpty else {
            return ToolsMatrix(platforms: [], rows: [])
        }

        var byPlatform: [String: [ToolRow]] = [:]
        var firstFailure: Error?

        await withTaskGroup(of: (String, Result<[ToolRow], Error>).self) { group in
            for platform in platforms {
                group.addTask {
                    do {
                        return (platform, .success(try await list(runner: runner, platform: platform)))
                    } catch {
                        return (platform, .failure(error))
                    }
                }
            }

            for await (platform, result) in group {
                switch result {
                case .success(let rows):
                    byPlatform[platform] = rows
                case .failure(let error):
                    if firstFailure == nil {
                        firstFailure = error
                    }
                }
            }
        }

        if byPlatform.isEmpty, let firstFailure {
            throw firstFailure
        }
        return makeMatrix(platforms: platforms, byPlatform: byPlatform)
    }

    private static func platformArgs(_ platform: String?) -> [String] {
        platform.map { ["--platform", $0] } ?? []
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
            // Scraping" stays a single field — the whitespace-greedy variant
            // in `CLIFieldParsing.splitFields` would shred the emoji + label.
            var fields = remainder
                .split(separator: /\s{2,}/)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
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
            let parts = CLIFieldParsing.splitFields(remainder)
            guard let name = parts.first else { return nil }
            let platform = parts.count >= 2 ? parts[1...].joined(separator: " ") : nil
            return ToolRow(name: name, platform: platform, enabled: enabled)
        }
        let parts = CLIFieldParsing.splitFields(line)
        guard let name = parts.first else { return nil }
        if parts.count == 1 {
            return ToolRow(name: name, platform: nil, enabled: true)
        }
        // Try: name <enabled>
        if parts.count == 2, let flag = CLIFieldParsing.parseBool(parts[1]) {
            return ToolRow(name: name, platform: nil, enabled: flag)
        }
        // Try: name platform enabled
        if parts.count >= 3, let flag = CLIFieldParsing.parseBool(parts[parts.count - 1]) {
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

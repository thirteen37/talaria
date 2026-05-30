import Foundation

public struct HermesProfileInfo: Equatable, Sendable, Identifiable {
    public let name: String
    /// True for the default profile (`~/.hermes`), which Hermes conventionally
    /// names `default`. Set from an explicit `Default` column / marker, or
    /// inferred from the name.
    public let isDefault: Bool
    /// Optional runtime status (`running`, `stopped`, …) when the CLI surfaces
    /// one; nil otherwise.
    public let status: String?

    public var id: String { name }

    public init(name: String, isDefault: Bool, status: String? = nil) {
        self.name = name
        self.isDefault = isDefault
        self.status = status
    }
}

public enum HermesProfilesError: Error, Equatable, Sendable, LocalizedError {
    case commandUnavailable(String)
    case commandFailed(exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .commandUnavailable(let detail):
            return "Profile command unavailable in this Hermes version: \(detail)"
        case .commandFailed(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "hermes profile failed (exit \(code))" : trimmed
        }
    }
}

public enum HermesProfiles {
    /// Conventional name of the default profile (lives at `~/.hermes`).
    public static let defaultProfileName = "default"

    /// Global `-p <name>` flag tokens that scope a `hermes` invocation to a
    /// named profile, or empty for the default profile (`nil`/empty/`default`
    /// all yield no `-p`, which is what the window's shared dashboard already
    /// serves). Used for a local argv where no shell quoting is applied —
    /// `[hermesPath] + cliFlag(name) + ["acp"]` and friends.
    public static func cliFlag(_ name: String?) -> [String] {
        guard let name, !name.isEmpty, name != defaultProfileName else { return [] }
        return ["-p", name]
    }

    /// Like ``cliFlag(_:)`` but single-quotes the name for a remote shell
    /// command line, matching how the hermes path and env vars are quoted.
    public static func remoteCLIFlag(_ name: String?) -> [String] {
        guard let name, !name.isEmpty, name != defaultProfileName else { return [] }
        return ["-p", ShellQuoting.shellQuote(name)]
    }

    public static func list(runner: HermesAdminRunning) async throws -> [HermesProfileInfo] {
        let result = try await runner.run(HermesAdminCommand(arguments: ["profile", "list"]))
        try ensureSuccess(result)
        return ensureDefault(parse(result.stdout))
    }

    // The eventual write seam, deferred this iteration:
    // func configSet(runner: HermesAdminRunning, dest: String, keyPath: String, value: String) async throws
    //   → HermesAdminCommand(arguments: ["-p", dest, "config", "set", "--", keyPath, value])

    /// Tolerant parser modeled on ``HermesSkills/parse(_:)``. Supported shapes:
    ///   * Rich box-drawing tables (`┃ Name ┃ Default ┃ Status ┃`) — header row
    ///     drives column mapping.
    ///   * Plain lines `name [markers…] [status…]`, with an optional leading
    ///     `*` / embedded `(default)` marker; the `default`-named row is always
    ///     flagged regardless of marker.
    public static func parse(_ text: String) -> [HermesProfileInfo] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.contains(where: { $0.contains("│") || $0.contains("┃") }) {
            return parseRichTable(lines: lines)
        }
        var rows: [HermesProfileInfo] = []
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

    /// Guarantees a `default` row exists (prepended) even if the CLI omitted it
    /// — the comparison UI always offers `default` as the source profile.
    public static func ensureDefault(_ profiles: [HermesProfileInfo]) -> [HermesProfileInfo] {
        if profiles.contains(where: { $0.name == defaultProfileName }) {
            return profiles
        }
        return [HermesProfileInfo(name: defaultProfileName, isDefault: true, status: nil)] + profiles
    }

    private static func parseRichTable(lines: [String]) -> [HermesProfileInfo] {
        var rows: [HermesProfileInfo] = []
        var columnMap: [String: Int] = [:]
        for raw in lines {
            if !raw.contains("│") && !raw.contains("┃") { continue }
            let cells = CLIFieldParsing.splitRichCells(raw)
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
            let defaultCell = columnMap["default"].flatMap { $0 < cells.count ? cells[$0] : nil }
            let statusCell = columnMap["status"].flatMap { $0 < cells.count ? cells[$0] : nil }
            let isDefault = (defaultCell.flatMap(CLIFieldParsing.parseBool) ?? false)
                || name.lowercased() == defaultProfileName
            let status = statusCell.flatMap { $0.isEmpty ? nil : $0 }
            rows.append(HermesProfileInfo(name: name, isDefault: isDefault, status: status))
        }
        return rows
    }

    private static let defaultMarkers: Set<String> = ["*", "(default)", "[default]", "default*"]

    private static func parseLine(_ line: String) -> HermesProfileInfo? {
        var fields = CLIFieldParsing.splitFields(line)
        guard !fields.isEmpty else { return nil }
        var isDefault = false
        if fields.first == "*" {
            isDefault = true
            fields.removeFirst()
        }
        guard let name = fields.first else { return nil }
        fields.removeFirst()
        var statusTokens: [String] = []
        for field in fields {
            if defaultMarkers.contains(field.lowercased()) {
                isDefault = true
            } else {
                statusTokens.append(field)
            }
        }
        if name.lowercased() == defaultProfileName {
            isDefault = true
        }
        let status = statusTokens.isEmpty ? nil : statusTokens.joined(separator: " ")
        return HermesProfileInfo(name: name, isDefault: isDefault, status: status)
    }

    static func isHeaderLine(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        if stripped.allSatisfy({ $0 == "-" || $0 == "=" || $0 == "_" }), !stripped.isEmpty {
            return true
        }
        // Require a known second column alongside the `name` prefix (mirroring
        // HermesSkills' `name` + `enabled` guard). A bare `hasPrefix("name")`
        // would mistake a profile literally named "namespace" / "name-test"
        // for the header and silently drop it from the list.
        let lowered = line.lowercased()
        return lowered.hasPrefix("name") && (lowered.contains("status") || lowered.contains("default"))
    }

    static func ensureSuccess(_ result: HermesAdminResult) throws {
        guard result.exitCode != 0 else { return }
        let stderr = result.stderr.lowercased()
        // Mirror HermesSkills: match only command-shape failures so we don't
        // mislabel `env: hermes: No such file or directory` (a PATH failure)
        // as "version too old".
        if stderr.contains("unknown command")
            || stderr.contains("no such command")
            || stderr.contains("no such subcommand") {
            throw HermesProfilesError.commandUnavailable(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        throw HermesProfilesError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
    }
}

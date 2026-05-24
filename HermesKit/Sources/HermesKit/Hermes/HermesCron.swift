import Foundation

public struct CronJob: Equatable, Sendable, Identifiable {
    public let id: String
    public var schedule: String
    public var command: String
    public var enabled: Bool
    public var lastRun: Date?

    public init(id: String, schedule: String, command: String, enabled: Bool, lastRun: Date? = nil) {
        self.id = id
        self.schedule = schedule
        self.command = command
        self.enabled = enabled
        self.lastRun = lastRun
    }
}

public enum HermesCronError: Error, Equatable, Sendable, LocalizedError {
    case commandUnavailable(String)
    case commandFailed(exitCode: Int32, stderr: String)
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .commandUnavailable:
            return "Cron CRUD is unavailable in this Hermes version."
        case .commandFailed(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "hermes cron failed (exit \(code))" : trimmed
        case .parseError(let detail):
            return "Couldn't parse cron output: \(detail)"
        }
    }
}

public enum HermesCron {
    public static func list(runner: HermesAdminRunning) async throws -> [CronJob] {
        let result = try await runner.run(HermesAdminCommand(arguments: ["cron", "list"]))
        try ensureSuccess(result)
        return parse(result.stdout)
    }

    public static func add(runner: HermesAdminRunning, schedule: String, command: String) async throws {
        let result = try await runner.run(HermesAdminCommand(arguments: ["cron", "add", "--", schedule, command]))
        try ensureSuccess(result)
    }

    public static func update(runner: HermesAdminRunning, id: String, schedule: String, command: String) async throws {
        let result = try await runner.run(HermesAdminCommand(arguments: ["cron", "update", "--", id, schedule, command]))
        try ensureSuccess(result)
    }

    public static func delete(runner: HermesAdminRunning, id: String) async throws {
        let result = try await runner.run(HermesAdminCommand(arguments: ["cron", "delete", "--yes", "--", id]))
        try ensureSuccess(result)
    }

    public static func pause(runner: HermesAdminRunning, id: String) async throws {
        let result = try await runner.run(HermesAdminCommand(arguments: ["cron", "pause", "--", id]))
        try ensureSuccess(result)
    }

    public static func resume(runner: HermesAdminRunning, id: String) async throws {
        let result = try await runner.run(HermesAdminCommand(arguments: ["cron", "resume", "--", id]))
        try ensureSuccess(result)
    }

    public static func runNow(runner: HermesAdminRunning, id: String) async throws {
        let result = try await runner.run(HermesAdminCommand(arguments: ["cron", "run", "--", id]))
        try ensureSuccess(result)
    }

    /// Tolerant parser. Expected per-line shape (tab-separated or 2+ spaces):
    /// `id  schedule  command  enabled  lastRun?`
    /// Where `schedule` may contain spaces (cron expressions usually have 5
    /// fields), so we anchor on tabs first and fall back to a "two or more
    /// spaces" delimiter — that lets us preserve embedded single-spaces in
    /// the schedule and command fields.
    public static func parse(_ text: String) -> [CronJob] {
        var jobs: [CronJob] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if isHeaderLine(trimmed) { continue }
            if let job = parseLine(line) {
                jobs.append(job)
            }
        }
        return jobs
    }

    private static func parseLine(_ line: String) -> CronJob? {
        let fields = splitFields(line)
        guard fields.count >= 3 else { return nil }
        let id = fields[0]
        let schedule = fields[1]
        let command = fields[2]
        let enabled: Bool
        if fields.count >= 4, let flag = HermesSkills.parseBool(fields[3]) {
            enabled = flag
        } else {
            enabled = true
        }
        let lastRun: Date?
        if fields.count >= 5, !fields[4].isEmpty, fields[4] != "-" {
            lastRun = parseDate(fields[4])
        } else {
            lastRun = nil
        }
        return CronJob(id: id, schedule: schedule, command: command, enabled: enabled, lastRun: lastRun)
    }

    /// Split on tabs if present; otherwise on runs of 2+ spaces. Either form
    /// preserves single-spaces inside schedules ("0 9 * * 1-5") and commands.
    static func splitFields(_ line: String) -> [String] {
        if line.contains("\t") {
            return line.split(separator: "\t", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        }
        var fields: [String] = []
        var current = ""
        var spaceRun = 0
        for ch in line {
            if ch == " " {
                spaceRun += 1
            } else {
                if spaceRun >= 2 {
                    fields.append(current)
                    current = ""
                } else if spaceRun > 0 {
                    current.append(" ")
                }
                spaceRun = 0
                current.append(ch)
            }
        }
        if !current.isEmpty { fields.append(current) }
        return fields.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func parseDate(_ value: String) -> Date? {
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFractional.date(from: value) { return d }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: value) { return d }
        // Try "yyyy-MM-dd HH:mm:ss"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }

    static func isHeaderLine(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        if stripped.allSatisfy({ $0 == "-" || $0 == "=" || $0 == "_" }), !stripped.isEmpty {
            return true
        }
        let lowered = line.lowercased()
        if lowered.hasPrefix("id") && (lowered.contains("schedule") || lowered.contains("command")) {
            return true
        }
        return false
    }

    static func ensureSuccess(_ result: HermesAdminResult) throws {
        guard result.exitCode != 0 else { return }
        let stderr = result.stderr.lowercased()
        if stderr.contains("unknown command")
            || stderr.contains("no such command")
            || stderr.contains("not a hermes command")
            || stderr.contains("usage: hermes") && stderr.contains("cron") {
            throw HermesCronError.commandUnavailable(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        throw HermesCronError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
    }
}

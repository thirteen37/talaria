import Foundation

public struct UpdateStatus: Sendable, Equatable {
    /// Nil when the underlying `hermes update --check` output doesn't include
    /// a semver (e.g. the source-install build reports "N commits behind
    /// origin/main" instead of a version delta). The UI falls back to
    /// `detail` in that case.
    public let current: HermesVersion?
    public let latest: HermesVersion?
    public let available: Bool
    /// Human-readable freshness phrase for non-semver builds — e.g.
    /// "122 commits behind origin/main". Surfaces in the status banner
    /// when a version comparison isn't available.
    public let detail: String?

    public init(current: HermesVersion?, latest: HermesVersion?, available: Bool, detail: String? = nil) {
        self.current = current
        self.latest = latest
        self.available = available
        self.detail = detail
    }
}

public enum HermesUpdatesError: Error, Equatable, Sendable, LocalizedError {
    case commandUnavailable(String)
    case commandFailed(exitCode: Int32, stderr: String)
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .commandUnavailable:
            return "Update check is unavailable in this Hermes version."
        case .commandFailed(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "hermes update failed (exit \(code))" : trimmed
        case .parseError(let detail):
            return "Couldn't parse update output: \(detail)"
        }
    }
}

public enum HermesUpdates {
    public static func check(runner: HermesAdminRunning) async throws -> UpdateStatus {
        let result = try await runner.run(HermesAdminCommand(arguments: ["update", "--check"]))
        if result.exitCode != 0 {
            let stderr = result.stderr.lowercased()
            // Tightened from a bare `"no such"` so a PATH miss like `env:
            // hermes: No such file or directory` is reported as the runtime
            // failure it is, not as "this hermes version doesn't support it".
            if stderr.contains("unknown command")
                || stderr.contains("no such command")
                || stderr.contains("no such subcommand") {
                throw HermesUpdatesError.commandUnavailable(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            // Some installers exit non-zero only on "update available". Try to
            // parse anyway and only throw if parsing fails too.
        }
        if let status = parse(result.stdout) { return status }
        if result.exitCode != 0 {
            throw HermesUpdatesError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        throw HermesUpdatesError.parseError(result.stdout)
    }

    public static func apply(runner: HermesAdminRunning) -> AsyncThrowingStream<AdminEvent, Error> {
        runner.runStream(HermesAdminCommand(arguments: ["update"]))
    }

    /// Tolerates several common phrasings:
    ///   * `current 1.2.3, latest 1.3.0`
    ///   * `current: 1.2.3\nlatest: 1.3.0`
    ///   * `Up to date (1.2.3)`
    ///   * `Update available: 1.2.3 → 1.3.0`
    ///   * `Update available: N commits behind origin/main.` — what
    ///     source-installed hermes builds actually emit. No semver is
    ///     present; the status carries a `detail` string instead.
    public static func parse(_ text: String) -> UpdateStatus? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        // Find all version-like substrings.
        let versions = findVersions(in: trimmed)

        if lower.contains("up to date") || lower.contains("up-to-date") {
            // Allow the source-install up-to-date message too: it has no
            // version number but the freshness verdict is still meaningful.
            // For the descriptor we want the *complement* to the headline
            // ("Up to date"), not a repeat of it — `with origin/main` etc.
            let current = versions.first
            let detail: String? = current == nil ? extractUpToDateQualifier(in: trimmed) : nil
            return UpdateStatus(current: current, latest: current, available: false, detail: detail)
        }

        if lower.contains("update available") || lower.contains("→") || lower.contains("->") {
            if versions.count >= 2 {
                return UpdateStatus(current: versions[0], latest: versions[1], available: true)
            }
            // No semver in the "update available" notice — fall back to the
            // commits-behind phrasing. Extract the most informative line so
            // the banner doesn't show the "Run 'hermes update' to install"
            // footer or unrelated chatter.
            let detail = primaryAvailabilityLine(in: trimmed) ?? trimmed
            return UpdateStatus(current: nil, latest: nil, available: true, detail: detail)
        }

        // Generic "current X, latest Y" form
        let currentVersion = extractAfter("current", in: trimmed).flatMap(HermesVersion.init)
        let latestVersion = extractAfter("latest", in: trimmed).flatMap(HermesVersion.init)
        if let current = currentVersion {
            let available = latestVersion.map { $0 > current } ?? false
            return UpdateStatus(current: current, latest: latestVersion, available: available)
        }
        // Fallback: just one version means we're current.
        if versions.count == 1 {
            return UpdateStatus(current: versions[0], latest: versions[0], available: false)
        }
        return nil
    }

    /// For an "up to date" notice, returns the part of the line *after* the
    /// "up to date"/"up-to-date" verdict — e.g. given
    /// `"⚕ Up to date with origin/main."` we return `"with origin/main"`.
    /// Returns nil when the parse can't isolate a meaningful descriptor;
    /// the caller then leaves `detail` unset so the banner doesn't echo
    /// the headline back to itself.
    private static func extractUpToDateQualifier(in text: String) -> String? {
        let line = (text.split(separator: "\n").map(String.init)
            .first(where: { $0.localizedCaseInsensitiveContains("up to date") || $0.localizedCaseInsensitiveContains("up-to-date") })
            ?? text)
            .trimmingCharacters(in: .whitespaces)
        let trailingTrim = CharacterSet(charactersIn: ".!\t ")
        for phrase in ["up to date", "up-to-date"] {
            guard let range = line.range(of: phrase, options: .caseInsensitive) else { continue }
            let tail = line[range.upperBound...].trimmingCharacters(in: trailingTrim)
            if !tail.isEmpty {
                return tail
            }
        }
        return nil
    }

    /// Pick the shortest line that contains "update available" (case-
    /// insensitive). Hermes' source-install notice is multi-line with a
    /// "Run 'hermes update' to install." footer; we want only the headline.
    /// Strip a leading Rich glyph like `⚕`/`→` for a cleaner UI string.
    private static func primaryAvailabilityLine(in text: String) -> String? {
        let candidates = text.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let line = candidates.first(where: { $0.lowercased().contains("update available") }) else {
            return nil
        }
        guard let first = line.unicodeScalars.first else { return line }
        let isGlyph = !CharacterSet.letters.contains(first) && !CharacterSet.decimalDigits.contains(first)
        if isGlyph {
            return String(line.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    private static func findVersions(in text: String) -> [HermesVersion] {
        var results: [HermesVersion] = []
        let pattern = /(\d+)\.(\d+)\.(\d+)(?:-[A-Za-z0-9.\-]+)?/
        for match in text.matches(of: pattern) {
            if let v = HermesVersion(String(match.output.0)) {
                results.append(v)
            }
        }
        return results
    }

    private static func extractAfter(_ label: String, in text: String) -> String? {
        let pattern = "(?i)\(label)[: ]+([0-9][^\\s,]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 2 else {
            return nil
        }
        return nsText.substring(with: match.range(at: 1))
    }
}

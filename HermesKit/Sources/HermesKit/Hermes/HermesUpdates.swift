import Foundation

public struct UpdateStatus: Sendable, Equatable {
    public let current: HermesVersion
    public let latest: HermesVersion?
    public let available: Bool

    public init(current: HermesVersion, latest: HermesVersion?, available: Bool) {
        self.current = current
        self.latest = latest
        self.available = available
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
            if stderr.contains("unknown command") || stderr.contains("no such") {
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
    public static func parse(_ text: String) -> UpdateStatus? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        // Find all version-like substrings.
        let versions = findVersions(in: trimmed)

        if lower.contains("up to date") || lower.contains("up-to-date") {
            guard let current = versions.first else { return nil }
            return UpdateStatus(current: current, latest: current, available: false)
        }

        if lower.contains("update available") || lower.contains("→") || lower.contains("->") {
            guard versions.count >= 2 else { return nil }
            return UpdateStatus(current: versions[0], latest: versions[1], available: true)
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

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

    public init(raw: String, sections: [Section], exitCode: Int32) {
        self.raw = raw
        self.sections = sections
        self.exitCode = exitCode
    }
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
        let result = try await runner.run(HermesAdminCommand(arguments: ["doctor"]))
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
            exitCode: result.exitCode
        )
    }

    /// Best-effort section splitter. Section heuristics (any of):
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
        return sections
    }

    private static func matchHeader(_ line: String) -> String? {
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

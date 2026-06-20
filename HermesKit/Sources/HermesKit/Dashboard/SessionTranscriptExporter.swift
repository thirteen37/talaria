import Foundation

/// Builds a JSONL (JSON Lines) transcript from a session's dashboard messages:
/// one compact JSON object per line, encoding each ``DashboardMessage`` with its
/// snake_case keys. Keys are sorted so the same transcript always serializes
/// byte-for-byte identically (stable, diff-friendly exports). Empty input yields
/// an empty string — no trailing newline.
public enum SessionTranscriptExporter {
    public static func jsonl(from messages: [DashboardMessage]) -> String {
        guard !messages.isEmpty else {
            return ""
        }
        let encoder = JSONEncoder()
        // `.sortedKeys` makes the output deterministic across runs; slashes in
        // file-path content read better unescaped.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return messages.compactMap { message -> String? in
            guard let data = try? encoder.encode(message) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
        .joined(separator: "\n")
    }
}

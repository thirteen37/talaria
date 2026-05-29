import Foundation

/// Tokenizers shared by the CLI scrapers that still drive non-dashboard
/// surfaces (Tools enable/disable, Sessions rename). Lived in
/// `HermesSkills.swift` before that file was deleted; lifted here so the
/// remaining scrapers don't pull a dead module just for two helpers.
enum CLIFieldParsing {
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
}

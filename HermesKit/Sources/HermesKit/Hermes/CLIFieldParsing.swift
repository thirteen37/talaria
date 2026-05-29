import Foundation

/// Tokenizers shared by the CLI scrapers that still drive non-dashboard
/// surfaces (Tools enable/disable, Sessions rename, Profiles list). Lived in
/// `HermesSkills.swift` before that file was deleted; lifted here so the
/// remaining scrapers don't pull a dead module just for these helpers.
enum CLIFieldParsing {
    static func splitFields(_ line: String) -> [String] {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    /// Splits a Rich/box-drawing table row on its column separators
    /// (`│` / `┃`) and trims each cell. Used by scrapers that parse Hermes'
    /// pretty-printed tables (e.g. `hermes profile list`).
    static func splitRichCells(_ line: String) -> [String] {
        let parts = line.split(whereSeparator: { $0 == "│" || $0 == "┃" })
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
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

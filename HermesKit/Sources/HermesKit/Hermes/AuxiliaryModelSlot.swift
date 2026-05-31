import Foundation

/// Static metadata for Hermes' auxiliary model task slots — ordering and
/// friendly labels only. The Models screen drives its rows off the live keys
/// returned by `GET /api/model/auxiliary`; this table just decides display
/// order and human-readable names, falling back gracefully for any slot a
/// future Hermes adds that this build doesn't yet know about.
///
/// The canonical list mirrors `_AUX_TASK_SLOTS` in Hermes'
/// `hermes_cli/web_server.py`. Hermes' own docs lag (they still say "eight
/// slots"); the API is the source of truth, currently eleven.
public enum AuxiliaryModelSlot {
    /// Slot keys in the order Hermes declares (and returns) them.
    public static let canonicalOrder: [String] = [
        "vision",
        "web_extract",
        "compression",
        "skills_hub",
        "approval",
        "mcp",
        "title_generation",
        "triage_specifier",
        "kanban_decomposer",
        "profile_describer",
        "curator",
    ]

    private static let labels: [String: String] = [
        "vision": "Vision",
        "web_extract": "Web Extract",
        "compression": "Compression",
        "skills_hub": "Skills Hub",
        "approval": "Approval",
        "mcp": "MCP Routing",
        "title_generation": "Title Generation",
        "triage_specifier": "Triage Specifier",
        "kanban_decomposer": "Kanban Decomposer",
        "profile_describer": "Profile Describer",
        "curator": "Curator",
    ]

    /// Friendly display label for a slot key. Unknown keys are title-cased from
    /// their snake_case form (`"foo_bar"` → `"Foo Bar"`) so a newly-added slot
    /// still renders sensibly without a code change.
    public static func label(for task: String) -> String {
        if let known = labels[task] { return known }
        return task
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Sort rank for a slot key: its canonical index, or a large value (keeping
    /// unknown slots after the known ones) so the UI order stays deterministic.
    public static func rank(of task: String) -> Int {
        canonicalOrder.firstIndex(of: task) ?? canonicalOrder.count
    }
}

import Foundation

/// A Hindsight memory `tag`, classified by its namespace prefix. Hermes tags
/// retained memories with lineage refs `session:<id>` (the current session) and
/// `parent:<id>` (the *parent* session it was resumed/forked from) — both are
/// Hermes **session** ids. Anything else is a plain tag.
public enum HindsightTagRef: Equatable, Sendable {
    /// `session:<id>` — the chat session this memory was retained in.
    case session(id: String)
    /// `parent:<id>` — the parent chat session (a session id, not a memory id).
    case parentSession(id: String)
    /// Any other tag (e.g. a visibility tag like `user_a`).
    case plain(String)

    /// Classify a raw tag string. Splits on the first `:`; a recognized
    /// namespace with a non-empty value yields a typed ref, otherwise `.plain`.
    public static func parse(_ tag: String) -> HindsightTagRef {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(of: ":") else { return .plain(trimmed) }
        let namespace = String(trimmed[..<colon])
        let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return .plain(trimmed) }
        switch namespace {
        case "session": return .session(id: value)
        case "parent": return .parentSession(id: value)
        default: return .plain(trimmed)
        }
    }
}

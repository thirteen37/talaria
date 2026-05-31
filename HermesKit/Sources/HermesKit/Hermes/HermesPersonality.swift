import Foundation

/// A single Hermes personality: a named system-prompt overlay stored under
/// `agent.personalities` in `config.yaml`. Each value is either a plain prompt
/// string or a structured object (`description`, `system_prompt`, `tone`,
/// `style`). The editor shows `name` + the editable prompt text; `rawValue`
/// carries the original JSON so structured entries round-trip losslessly when
/// only the prompt is edited.
public struct HermesPersonality: Identifiable, Equatable, Sendable {
    public let name: String
    /// The editable text: a string value is itself; an object's text is its
    /// `system_prompt`. Tone/style are preserved in `rawValue`, not edited here.
    public let prompt: String
    /// The original `agent.personalities[name]` value, kept so a structured
    /// entry's `description`/`tone`/`style` survive a prompt edit.
    public let rawValue: JSONValue

    public var id: String { name }

    public init(name: String, prompt: String, rawValue: JSONValue) {
        self.name = name
        self.prompt = prompt
        self.rawValue = rawValue
    }

    // The two fixed config paths. Addressed as whole two-segment dotpaths whose
    // own segments never contain `.`; individual personality names are keyed
    // into the `agent.personalities` object map directly (never as a dotpath),
    // so a name containing `.` is safe.
    static let personalitiesPath = "agent.personalities"
    static let systemPromptPath = "agent.system_prompt"

    // MARK: - Read

    /// Pulls the personalities map (sorted by name for stable display, since
    /// `JSONValue.object` is unordered) and the active overlay prompt
    /// (`agent.system_prompt`, `""` when absent) out of a config document.
    public static func parse(_ config: JSONValue) -> (items: [HermesPersonality], activePrompt: String) {
        let map = personalitiesMap(in: config)
        let items = map
            .map { HermesPersonality(name: $0.key, prompt: editableText(of: $0.value), rawValue: $0.value) }
            .sorted { $0.name < $1.name }
        return (items, string(at: systemPromptPath, in: config))
    }

    /// Resolves a personality value to the prompt string Hermes would write to
    /// `agent.system_prompt` — mirroring Hermes' `_resolve_personality_prompt`
    /// (cli.py:7593): a string is itself; an object joins its non-empty
    /// `system_prompt` with `Tone:`/`Style:` lines. Used so active-match and the
    /// Activate action agree with Hermes.
    public static func resolvedPrompt(for value: JSONValue) -> String {
        switch value {
        case let .string(text):
            return text
        case let .object(fields):
            var parts: [String] = [stringField(fields, "system_prompt")]
            if let tone = nonEmptyField(fields, "tone") { parts.append("Tone: \(tone)") }
            if let style = nonEmptyField(fields, "style") { parts.append("Style: \(style)") }
            return parts.filter { !$0.isEmpty }.joined(separator: "\n")
        default:
            return ""
        }
    }

    // MARK: - Write

    /// Sets `agent.personalities[name]` to `prompt`. When the entry being edited
    /// (`oldName ?? name`) is a structured object, only its `system_prompt` is
    /// replaced so `description`/`tone`/`style` survive; otherwise a plain string
    /// is written. Passing `oldName` (≠ `name`) renames: the old key is removed
    /// and its value migrated to the new key.
    public static func upsert(
        name: String,
        prompt: String,
        into config: JSONValue,
        oldName: String? = nil
    ) -> JSONValue {
        var map = personalitiesMap(in: config)
        let source = map[oldName ?? name]
        if let oldName, oldName != name {
            map.removeValue(forKey: oldName)
        }
        if case let .object(fields)? = source {
            var updated = fields
            updated["system_prompt"] = .string(prompt)
            map[name] = .object(updated)
        } else {
            map[name] = .string(prompt)
        }
        return setPersonalities(map, in: config)
    }

    /// Drops `agent.personalities[name]`. If the removed entry's resolved prompt
    /// equals the current `agent.system_prompt`, also clears the overlay so a
    /// deleted personality doesn't leave its prompt active.
    public static func remove(name: String, from config: JSONValue) -> JSONValue {
        var map = personalitiesMap(in: config)
        let removed = map.removeValue(forKey: name)
        var result = setPersonalities(map, in: config)
        if let removed, resolvedPrompt(for: removed) == string(at: systemPromptPath, in: config) {
            result = setActive(resolvedPrompt: "", in: result)
        }
        return result
    }

    /// Writes `agent.system_prompt`. An empty string clears the overlay (matching
    /// Hermes' `/personality none`).
    public static func setActive(resolvedPrompt: String, in config: JSONValue) -> JSONValue {
        ProfileConfigForm.setValue(.string(resolvedPrompt), at: systemPromptPath, in: config)
    }

    // MARK: - Helpers

    /// The personalities map, or `[:]` when `agent.personalities` is absent or
    /// not an object.
    static func personalitiesMap(in config: JSONValue) -> [String: JSONValue] {
        if case let .object(map)? = ProfileConfigForm.value(at: personalitiesPath, in: config) {
            return map
        }
        return [:]
    }

    private static func setPersonalities(_ map: [String: JSONValue], in config: JSONValue) -> JSONValue {
        ProfileConfigForm.setValue(.object(map), at: personalitiesPath, in: config)
    }

    /// The editable text for a value: a string is itself; an object's text is
    /// its `system_prompt`; anything else has none.
    private static func editableText(of value: JSONValue) -> String {
        switch value {
        case let .string(text): return text
        case let .object(fields): return stringField(fields, "system_prompt")
        default: return ""
        }
    }

    private static func string(at path: String, in config: JSONValue) -> String {
        if case let .string(text)? = ProfileConfigForm.value(at: path, in: config) {
            return text
        }
        return ""
    }

    private static func stringField(_ fields: [String: JSONValue], _ key: String) -> String {
        if case let .string(text)? = fields[key] { return text }
        return ""
    }

    private static func nonEmptyField(_ fields: [String: JSONValue], _ key: String) -> String? {
        let text = stringField(fields, key)
        return text.isEmpty ? nil : text
    }
}

import Foundation

/// A single editable config value, coerced to the control class the schema
/// advertised. `list` elements are stringified for row editing and coerced back
/// to their original JSON element types on merge. `missing` is a schema field
/// with no value in the current config (the editor shows an empty control).
/// `raw` carries an unmodeled value (a nested object, or a type that doesn't
/// match its schema) verbatim so it round-trips losslessly and renders
/// read-only.
public enum ConfigValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case list([String])
    case missing
    case raw(JSONValue)
}

/// One row in the structured editor: a config dotpath, its schema (nil for
/// unmodeled `other` keys), and its current value.
public struct ConfigFormField: Equatable, Sendable, Identifiable {
    public let key: String
    public let schema: ConfigFieldSchema?
    public let value: ConfigValue
    public let category: String

    public var id: String { key }

    public init(key: String, schema: ConfigFieldSchema?, value: ConfigValue, category: String) {
        self.key = key
        self.schema = schema
        self.value = value
        self.category = category
    }
}

extension ConfigFormField {
    /// True when the query is a substring of the key or the schema description.
    /// Caller passes an already-trimmed, non-empty query; matching is
    /// case-insensitive.
    func matchesSearch(_ query: String) -> Bool {
        if key.localizedCaseInsensitiveContains(query) { return true }
        if let description = schema?.description, description.localizedCaseInsensitiveContains(query) { return true }
        return false
    }
}

/// A titled group of fields, mirroring the dashboard's category tabs.
public struct ConfigFormCategory: Equatable, Sendable, Identifiable {
    public let name: String
    public let fields: [ConfigFormField]

    public var id: String { name }

    public init(name: String, fields: [ConfigFormField]) {
        self.name = name
        self.fields = fields
    }
}

/// The structured, schema-driven view of one profile's config: schema fields
/// grouped into ordered categories, plus a trailing `other` bucket for config
/// keys the schema doesn't describe. Pure value type — the view harness builds
/// one from a `(schema, config)` pair and merges edits back via ``merged(into:edits:)``.
public struct ProfileConfigForm: Equatable, Sendable {
    public let categories: [ConfigFormCategory]

    public init(categories: [ConfigFormCategory]) {
        self.categories = categories
    }

    /// Synthetic bucket holding config keys absent from the schema.
    public static let otherCategoryName = "other"

    /// Categories whose fields match `query` (case-insensitive substring of the
    /// dotpath key OR the schema description), with empty categories dropped. A
    /// blank/whitespace query returns all categories unchanged. Purely
    /// presentational — never touches values/dirty/save.
    public func categories(matchingSearch query: String) -> [ConfigFormCategory] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return categories }
        return categories.compactMap { category in
            let fields = category.fields.filter { $0.matchesSearch(q) }
            return fields.isEmpty ? nil : ConfigFormCategory(name: category.name, fields: fields)
        }
    }

    public func field(for key: String) -> ConfigFormField? {
        for category in categories {
            if let field = category.fields.first(where: { $0.key == key }) {
                return field
            }
        }
        return nil
    }

    /// Builds the structured form. Schema fields resolve their value from
    /// `config` by dotpath and group by category (ordered per the schema's
    /// `categoryOrder`, then any remaining categories alphabetically). Config
    /// leaves the schema doesn't cover land in a trailing `other` category,
    /// sorted alphabetically for deterministic display (the GET object's key
    /// order isn't preserved across the JSON boundary).
    public static func make(schema: DashboardConfigSchema, config: JSONValue) -> ProfileConfigForm {
        var fieldsByCategory: [String: [ConfigFormField]] = [:]
        var categoryAppearance: [String] = []
        let knownKeys = Set(schema.orderedKeys)

        for key in schema.orderedKeys {
            guard let fieldSchema = schema.field(for: key) else { continue }
            let resolved = lookup(key, in: config)
            let value = coerce(resolved, to: fieldSchema.type)
            let field = ConfigFormField(key: key, schema: fieldSchema, value: value, category: fieldSchema.category)
            if fieldsByCategory[fieldSchema.category] == nil {
                categoryAppearance.append(fieldSchema.category)
            }
            fieldsByCategory[fieldSchema.category, default: []].append(field)
        }

        // Config leaves not described by the schema → `other`.
        var otherFields: [ConfigFormField] = []
        for (path, value) in flatten(config) where !knownKeys.contains(path) {
            otherFields.append(
                ConfigFormField(key: path, schema: nil, value: inferred(value), category: otherCategoryName)
            )
        }
        otherFields.sort { $0.key < $1.key }

        // Order: categoryOrder entries that have fields, then remaining
        // categories alphabetically, then `other`.
        var orderedNames: [String] = []
        for name in schema.categoryOrder where fieldsByCategory[name] != nil {
            orderedNames.append(name)
        }
        let remaining = categoryAppearance
            .filter { !orderedNames.contains($0) }
            .sorted()
        orderedNames.append(contentsOf: remaining)

        var categories = orderedNames.map { name in
            ConfigFormCategory(name: name, fields: fieldsByCategory[name] ?? [])
        }
        if !otherFields.isEmpty {
            categories.append(ConfigFormCategory(name: otherCategoryName, fields: otherFields))
        }

        return ProfileConfigForm(categories: categories)
    }

    /// Non-destructive merge: starts from the original full GET object and sets
    /// only the edited dotpaths, coercing each `ConfigValue` back to a
    /// `JSONValue`. Unknown and unedited keys are untouched — this is the
    /// guarantee that a PUT never clobbers config the editor didn't surface.
    public static func merged(into original: JSONValue, edits: [String: ConfigValue]) -> JSONValue {
        var result = original
        // Deterministic application order so nested edits are reproducible.
        for key in edits.keys.sorted() {
            guard let value = edits[key] else { continue }
            let originalLeaf = lookup(key, in: original)
            let json = jsonValue(for: value, original: originalLeaf)
            result = setting(key.components(separatedBy: "."), to: json, in: result)
        }
        return result
    }

    /// Computes the structured edit-delta for a working config relative to a
    /// baseline: every leaf dotpath whose value differs from (or is absent in)
    /// `base`, coerced to a `ConfigValue` by its schema type (inferred for keys
    /// the schema doesn't describe). Used to carry YAML-pane changes back into
    /// the structured editor and to drive the non-destructive ``merged(into:edits:)``
    /// on save. Key deletions can't be represented as edits, so a key removed
    /// from `working` is not reflected — the structured path is additive/mutating
    /// by design (the YAML pane is the surface for removals).
    public static func edits(
        from working: JSONValue,
        base: JSONValue,
        schema: DashboardConfigSchema?
    ) -> [String: ConfigValue] {
        var result: [String: ConfigValue] = [:]
        for (path, leaf) in flatten(working) where lookup(path, in: base) != leaf {
            let type = schema?.field(for: path)?.type
            let value = configValue(from: leaf, schemaType: type)
            // A schema-typed scalar that didn't coerce (e.g. empty / non-numeric
            // text in a number field) is invalid input. Drop it so the PUT leaves
            // the key at its existing value instead of writing a wrong-typed
            // scalar. `.raw` for a schema-less key is a legitimate passthrough and
            // is kept.
            if let type, type == .number || type == .boolean, case .raw = value {
                continue
            }
            result[path] = value
        }
        return result
    }

    /// Converts a JSON leaf to a `ConfigValue`, coercing to `schemaType` when
    /// known and inferring from the JSON type otherwise.
    public static func configValue(from json: JSONValue, schemaType: ConfigFieldType?) -> ConfigValue {
        if let schemaType {
            return coerce(json, to: schemaType)
        }
        return inferred(json)
    }

    // MARK: - Live working-config access (for the editor's field bindings)

    /// Reads the value at a dotpath in a config object, or nil if absent.
    public static func value(at dotpath: String, in config: JSONValue) -> JSONValue? {
        lookup(dotpath, in: config)
    }

    /// Returns a copy of `config` with `dotpath` set to `value`, creating
    /// intermediate objects as needed.
    public static func setValue(_ value: JSONValue, at dotpath: String, in config: JSONValue) -> JSONValue {
        setting(dotpath.components(separatedBy: "."), to: value, in: config)
    }

    // MARK: - Value resolution

    /// Navigates a dotpath into a JSON object, returning the leaf or nil.
    static func lookup(_ key: String, in config: JSONValue) -> JSONValue? {
        var current = config
        for component in key.components(separatedBy: ".") {
            guard case .object(let map) = current, let next = map[component] else { return nil }
            current = next
        }
        return current
    }

    private static func coerce(_ value: JSONValue?, to type: ConfigFieldType) -> ConfigValue {
        guard let value else { return .missing }
        switch type {
        case .string, .select:
            if let string = stringValue(value) { return .string(string) }
            return .raw(value)
        case .number:
            if case .number(let n) = value { return .number(n) }
            if case .string(let s) = value, let n = Double(s) { return .number(n) }
            return .raw(value)
        case .boolean:
            if case .bool(let b) = value { return .bool(b) }
            return .raw(value)
        case .list:
            if case .array(let elements) = value {
                return .list(elements.map { stringValue($0) ?? "" })
            }
            return .raw(value)
        }
    }

    /// Infers a `ConfigValue` for an unmodeled `other` leaf from its JSON type.
    private static func inferred(_ value: JSONValue) -> ConfigValue {
        switch value {
        case .string(let s): return .string(s)
        case .number(let n): return .number(n)
        case .bool(let b): return .bool(b)
        case .array(let elements): return .list(elements.map { stringValue($0) ?? "" })
        case .object, .null: return .raw(value)
        }
    }

    /// Renders a JSON scalar to a plain string for a text/select control.
    /// Integers render without a trailing `.0`. Returns nil for containers.
    private static func stringValue(_ value: JSONValue) -> String? {
        switch value {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
            return String(n)
        case .null: return ""
        case .array, .object: return nil
        }
    }

    // MARK: - Merge helpers

    private static func jsonValue(for value: ConfigValue, original: JSONValue?) -> JSONValue {
        switch value {
        case .string(let s): return .string(s)
        case .number(let n): return .number(n)
        case .bool(let b): return .bool(b)
        case .missing: return .null
        case .raw(let json): return json
        case .list(let elements):
            // Preserve original element JSON types where the original list had a
            // value at the same index (round-trip fidelity); infer for any new
            // elements appended past the original length.
            var originalElements: [JSONValue] = []
            if case .array(let arr)? = original { originalElements = arr }
            let coerced = elements.enumerated().map { index, string -> JSONValue in
                let template = index < originalElements.count ? originalElements[index] : nil
                return coerceElement(string, like: template)
            }
            return .array(coerced)
        }
    }

    /// Coerces an edited list element string back to the JSON type of the
    /// element it replaces. With no template (a newly added element) it stays a
    /// string — the safe default for Hermes' predominantly string-valued lists.
    private static func coerceElement(_ string: String, like template: JSONValue?) -> JSONValue {
        switch template {
        case .number:
            if let n = Double(string) { return .number(n) }
            return .string(string)
        case .bool:
            if string == "true" { return .bool(true) }
            if string == "false" { return .bool(false) }
            return .string(string)
        default:
            return .string(string)
        }
    }

    /// Returns a copy of `config` with `path` set to `value`, creating
    /// intermediate objects as needed.
    private static func setting(_ path: [String], to value: JSONValue, in config: JSONValue) -> JSONValue {
        guard let head = path.first else { return value }
        var map: [String: JSONValue]
        if case .object(let existing) = config { map = existing } else { map = [:] }
        if path.count == 1 {
            map[head] = value
        } else {
            let child = map[head] ?? .object([:])
            map[head] = setting(Array(path.dropFirst()), to: value, in: child)
        }
        return .object(map)
    }

    /// Flattens a JSON object into ordered `(dotpath, leaf)` pairs. Objects
    /// recurse; scalars and arrays are leaves (mirrors
    /// ``HermesConfigDocument``'s dotpath convention). Sorted by key at each
    /// level for determinism, since JSONValue object keys aren't ordered.
    static func flatten(_ config: JSONValue) -> [(String, JSONValue)] {
        var result: [(String, JSONValue)] = []
        flattenInto(config, prefix: "", into: &result)
        return result
    }

    private static func flattenInto(_ value: JSONValue, prefix: String, into result: inout [(String, JSONValue)]) {
        switch value {
        case .object(let map) where !map.isEmpty:
            for key in map.keys.sorted() {
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                flattenInto(map[key]!, prefix: path, into: &result)
            }
        default:
            if !prefix.isEmpty { result.append((prefix, value)) }
        }
    }
}

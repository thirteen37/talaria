import Foundation
import Yams

/// A single flattened config value: a dotted key-path and its rendered value.
/// The dotted `keyPath` is the full path from the document root
/// (`model.default`, `agent.timeout`) and doubles as the future
/// `hermes -p <dest> config set <keyPath> <value>` target — which is why a
/// list collapses to **one** entry (`model.fallbacks = [a, b]`) rather than
/// one row per index.
public struct ConfigEntry: Equatable, Sendable, Identifiable {
    public let keyPath: String
    public let value: String

    public var id: String { keyPath }

    public init(keyPath: String, value: String) {
        self.keyPath = keyPath
        self.value = value
    }
}

/// A top-level grouping of entries. The name is the top-level mapping key
/// (`agent`, `terminal`, …); loose top-level scalars are gathered under the
/// synthetic `general` section.
public struct ConfigSection: Equatable, Sendable, Identifiable {
    public let name: String
    public let entries: [ConfigEntry]

    public var id: String { name }

    public init(name: String, entries: [ConfigEntry]) {
        self.name = name
        self.entries = entries
    }
}

public enum HermesConfigError: Error, Equatable, Sendable, LocalizedError {
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .parseFailed(let detail):
            return "Couldn't parse config.yaml: \(detail)"
        }
    }
}

/// Ordered, section-grouped view of a profile's `config.yaml`, parsed via Yams
/// so the mapping order Hermes emits is preserved (the UI renders sections in
/// the same order as the Hermes dashboard rather than alphabetizing them).
public struct HermesConfigDocument: Equatable, Sendable {
    public let sections: [ConfigSection]

    public init(sections: [ConfigSection]) {
        self.sections = sections
    }

    /// Synthetic bucket name for loose top-level scalars (keys not nested under
    /// a section mapping).
    public static let generalSectionName = "general"

    public static func parse(_ text: String) throws -> HermesConfigDocument {
        let node: Node?
        do {
            node = try Yams.compose(yaml: text)
        } catch {
            throw HermesConfigError.parseFailed(String(describing: error))
        }
        // Empty document (blank / comments-only) → no sections.
        guard let node else { return HermesConfigDocument(sections: []) }
        guard case .mapping(let root) = node else {
            throw HermesConfigError.parseFailed("expected a top-level mapping")
        }

        var sections: [ConfigSection] = []
        var generalEntries: [ConfigEntry] = []
        for (keyNode, valueNode) in root {
            guard let key = keyNode.string else { continue }
            if case .mapping(let nested) = valueNode {
                var entries: [ConfigEntry] = []
                flatten(prefix: key, mapping: nested, into: &entries)
                sections.append(ConfigSection(name: key, entries: entries))
            } else {
                // Top-level scalar or list → general bucket. The key-path stays
                // bare (e.g. `log_level`) so it maps to a top-level `config set`.
                generalEntries.append(ConfigEntry(keyPath: key, value: inlineValue(valueNode)))
            }
        }

        if !generalEntries.isEmpty {
            if let idx = sections.firstIndex(where: { $0.name == generalSectionName }) {
                // A real `general:` mapping already exists — fold loose scalars in.
                let merged = generalEntries + sections[idx].entries
                sections[idx] = ConfigSection(name: generalSectionName, entries: merged)
            } else {
                sections.insert(ConfigSection(name: generalSectionName, entries: generalEntries), at: 0)
            }
        }

        return HermesConfigDocument(sections: sections)
    }

    /// Recursively flattens a nested mapping into dotted key-paths. Mappings
    /// recurse; scalars and lists are leaves (lists rendered inline).
    private static func flatten(prefix: String, mapping: Node.Mapping, into entries: inout [ConfigEntry]) {
        for (keyNode, valueNode) in mapping {
            guard let key = keyNode.string else { continue }
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if case .mapping(let nested) = valueNode {
                flatten(prefix: path, mapping: nested, into: &entries)
            } else {
                entries.append(ConfigEntry(keyPath: path, value: inlineValue(valueNode)))
            }
        }
    }

    /// Renders a value node to a single display string. Scalars use their raw
    /// text; lists/maps collapse to a compact inline form (`[a, b]`,
    /// `{k: v}`) so each value occupies one comparison row.
    private static func inlineValue(_ node: Node) -> String {
        switch node {
        case .scalar(let scalar):
            return scalar.string
        case .sequence(let sequence):
            return "[" + sequence.map(inlineValue).joined(separator: ", ") + "]"
        case .mapping(let mapping):
            let parts = mapping.map { "\(($0.key.string ?? "")): \(inlineValue($0.value))" }
            return "{" + parts.joined(separator: ", ") + "}"
        default:
            // `.alias` (anchor references) — vanishingly rare in a Hermes
            // config; render its resolved scalar if any, else empty.
            return node.string ?? ""
        }
    }
}

// MARK: - Comparison

public enum ConfigRowStatus: Sendable, Equatable {
    case same
    case changed
    case onlyInSource
    case onlyInDest
}

/// One row of a side-by-side comparison for a single key-path.
public struct ConfigRowComparison: Equatable, Sendable, Identifiable {
    public let keyPath: String
    public let sourceValue: String?
    public let destValue: String?
    public let status: ConfigRowStatus

    public var id: String { keyPath }

    public init(keyPath: String, sourceValue: String?, destValue: String?, status: ConfigRowStatus) {
        self.keyPath = keyPath
        self.sourceValue = sourceValue
        self.destValue = destValue
        self.status = status
    }
}

/// A section's worth of comparison rows.
public struct SectionComparison: Equatable, Sendable, Identifiable {
    public let name: String
    public let rows: [ConfigRowComparison]

    public var id: String { name }

    /// True if any row differs (changed / only-in-one-side). Drives the
    /// "Differences only" filter in the UI.
    public var hasDifferences: Bool {
        rows.contains { $0.status != .same }
    }

    public init(name: String, rows: [ConfigRowComparison]) {
        self.name = name
        self.rows = rows
    }
}

/// Section-grouped diff of two config documents. Sections and rows union with
/// **source order first**, then source-absent items appended in dest order, so
/// the reference profile's layout drives the display.
public struct ConfigComparison: Equatable, Sendable {
    public let sections: [SectionComparison]

    public init(source: HermesConfigDocument, dest: HermesConfigDocument) {
        let sourceByName = Dictionary(source.sections.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let destByName = Dictionary(dest.sections.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        var orderedNames = source.sections.map(\.name)
        for section in dest.sections where sourceByName[section.name] == nil {
            orderedNames.append(section.name)
        }

        sections = orderedNames.map { name in
            let sourceEntries = sourceByName[name]?.entries ?? []
            let destEntries = destByName[name]?.entries ?? []
            let sourceValues = Dictionary(sourceEntries.map { ($0.keyPath, $0.value) }, uniquingKeysWith: { first, _ in first })
            let destValues = Dictionary(destEntries.map { ($0.keyPath, $0.value) }, uniquingKeysWith: { first, _ in first })

            var keyOrder = sourceEntries.map(\.keyPath)
            for entry in destEntries where sourceValues[entry.keyPath] == nil {
                keyOrder.append(entry.keyPath)
            }

            let rows = keyOrder.map { keyPath -> ConfigRowComparison in
                let sourceValue = sourceValues[keyPath]
                let destValue = destValues[keyPath]
                let status: ConfigRowStatus
                switch (sourceValue, destValue) {
                case let (source?, dest?):
                    status = source == dest ? .same : .changed
                case (_?, nil):
                    status = .onlyInSource
                case (nil, _?):
                    status = .onlyInDest
                case (nil, nil):
                    status = .same
                }
                return ConfigRowComparison(keyPath: keyPath, sourceValue: sourceValue, destValue: destValue, status: status)
            }
            return SectionComparison(name: name, rows: rows)
        }
    }
}

import Foundation
import Yams

/// UI control class for a single config field, as advertised by the dashboard's
/// `GET /api/config/schema`. The wire `type` string drives which SwiftUI
/// control the editor renders.
public enum ConfigFieldType: String, Equatable, Sendable, CaseIterable {
    case string
    case number
    case boolean
    case list
    case select

    /// Maps a wire `type` string to a case, falling back to ``string`` for any
    /// value this build doesn't model yet (a newer Hermes can introduce field
    /// types — e.g. an `object` leaf — that must degrade to a plain text field
    /// rather than fail the whole schema decode).
    public init(wire raw: String) {
        self = ConfigFieldType(rawValue: raw) ?? .string
    }
}

/// Schema for one config field. `key` is the full dotpath (`terminal.backend`,
/// `model`) — injected from the `fields` map key, which the wire object doesn't
/// repeat inside each entry. `options` is present only for ``ConfigFieldType/select``.
public struct ConfigFieldSchema: Equatable, Sendable, Identifiable {
    public let key: String
    public let type: ConfigFieldType
    public let description: String?
    public let category: String
    public let options: [String]?

    public var id: String { key }

    public init(
        key: String,
        type: ConfigFieldType,
        description: String?,
        category: String,
        options: [String]? = nil
    ) {
        self.key = key
        self.type = type
        self.description = description
        self.category = category
        self.options = options
    }
}

/// Decoded `GET /api/config/schema` payload: the profile-agnostic field schema
/// plus the category display order. Drives the structured editor's control
/// selection, labels, and section grouping.
///
/// Parsed via Yams rather than `JSONDecoder` because the dashboard emits its
/// `fields` map in a meaningful order (Python dict insertion order — e.g.
/// `model_context_length` injected right after `model`), and Foundation's
/// `JSONDecoder` hashes object keys, losing that order. Yams preserves mapping
/// order, the same way ``HermesConfigDocument`` parses `config.yaml`. JSON is a
/// subset of YAML, so the JSON response composes cleanly.
public struct DashboardConfigSchema: Equatable, Sendable {
    /// Field schemas keyed by dotpath, for O(1) value resolution.
    public let fields: [String: ConfigFieldSchema]
    /// Dotpaths in the order the dashboard emitted them.
    public let orderedKeys: [String]
    /// Category display order; categories not listed sort after these.
    public let categoryOrder: [String]

    public init(
        fields: [String: ConfigFieldSchema],
        orderedKeys: [String],
        categoryOrder: [String]
    ) {
        self.fields = fields
        self.orderedKeys = orderedKeys
        self.categoryOrder = categoryOrder
    }

    public func field(for key: String) -> ConfigFieldSchema? {
        fields[key]
    }

    /// Field schemas in wire order.
    public var orderedFields: [ConfigFieldSchema] {
        orderedKeys.compactMap { fields[$0] }
    }

    public init(data: Data) throws {
        let text = String(decoding: data, as: UTF8.self)
        let node: Node?
        do {
            node = try Yams.compose(yaml: text)
        } catch {
            throw DashboardClientError.decoding("config schema: \(String(describing: error))")
        }
        guard case .mapping(let root)? = node else {
            throw DashboardClientError.decoding("config schema: expected a top-level object")
        }

        var fields: [String: ConfigFieldSchema] = [:]
        var orderedKeys: [String] = []
        if case .mapping(let fieldsMap)? = root["fields"] {
            for (keyNode, valueNode) in fieldsMap {
                guard let key = keyNode.string, case .mapping(let entry) = valueNode else { continue }
                let typeRaw = entry["type"]?.string ?? "string"
                let options: [String]?
                if case .sequence(let seq)? = entry["options"] {
                    options = seq.compactMap { $0.string }
                } else {
                    options = nil
                }
                let schema = ConfigFieldSchema(
                    key: key,
                    type: ConfigFieldType(wire: typeRaw),
                    description: entry["description"]?.string,
                    category: entry["category"]?.string ?? "general",
                    options: options
                )
                fields[key] = schema
                orderedKeys.append(key)
            }
        }

        var categoryOrder: [String] = []
        if case .sequence(let order)? = root["category_order"] {
            categoryOrder = order.compactMap { $0.string }
        }

        self.fields = fields
        self.orderedKeys = orderedKeys
        self.categoryOrder = categoryOrder
    }
}

import Foundation

/// One row of a two-column editable comparison for a single config dotpath. The
/// `key` is the **unioned** dotpath (the row's identity) — either side's field
/// may be `nil` when that profile's schema/config doesn't model the key, so the
/// row id can never come from a per-side field. Each side keeps its own
/// schema-derived `ConfigFormField` so its control class is decided independently.
public struct ComparisonRow: Equatable, Sendable, Identifiable {
    public let key: String
    public let sourceField: ConfigFormField?
    public let destField: ConfigFormField?

    public var id: String { key }

    public init(key: String, sourceField: ConfigFormField?, destField: ConfigFormField?) {
        self.key = key
        self.sourceField = sourceField
        self.destField = destField
    }
}

/// A titled group of comparison rows, mirroring one structured-editor category.
public struct ComparisonCategory: Equatable, Sendable, Identifiable {
    public let name: String
    public let rows: [ComparisonRow]

    public var id: String { name }

    public init(name: String, rows: [ComparisonRow]) {
        self.name = name
        self.rows = rows
    }
}

/// Aligns two structured forms row-by-row for the editable comparison. Purely a
/// union by dotted key — the two `DashboardConfigSchema`s are **never** merged,
/// since they can disagree on a key's type or category; each side keeps its own
/// schema-derived control and a side that lacks the key contributes `nil`.
///
/// Ordering mirrors the proven ``ConfigComparison`` union: source categories in
/// their existing order, then dest-only categories appended; within a category,
/// source keys in order, then dest-only keys appended. The row id is the unioned
/// key so it is stable regardless of which side supplied the field.
public func alignedComparison(
    source: ProfileConfigForm,
    dest: ProfileConfigForm
) -> [ComparisonCategory] {
    let sourceByName = Dictionary(
        source.categories.map { ($0.name, $0) },
        uniquingKeysWith: { first, _ in first }
    )
    let destByName = Dictionary(
        dest.categories.map { ($0.name, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    var orderedNames = source.categories.map(\.name)
    for category in dest.categories where sourceByName[category.name] == nil {
        orderedNames.append(category.name)
    }

    return orderedNames.map { name in
        let sourceFields = sourceByName[name]?.fields ?? []
        let destFields = destByName[name]?.fields ?? []
        let sourceByKey = Dictionary(
            sourceFields.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let destByKey = Dictionary(
            destFields.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var keyOrder = sourceFields.map(\.key)
        for field in destFields where sourceByKey[field.key] == nil {
            keyOrder.append(field.key)
        }

        let rows = keyOrder.map { key in
            ComparisonRow(key: key, sourceField: sourceByKey[key], destField: destByKey[key])
        }
        return ComparisonCategory(name: name, rows: rows)
    }
}

/// Filters aligned comparison categories to rows matching `query` (the unioned
/// key, or either side's field description), dropping empty categories. A
/// blank/whitespace query returns the categories unchanged. Purely
/// presentational — mirrors ``ProfileConfigForm/categories(matchingSearch:)``.
public func filteredComparison(_ categories: [ComparisonCategory], matchingSearch query: String) -> [ComparisonCategory] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return categories }
    return categories.compactMap { category in
        let rows = category.rows.filter { row in
            row.key.localizedCaseInsensitiveContains(q)
                || (row.sourceField?.matchesSearch(q) ?? false)
                || (row.destField?.matchesSearch(q) ?? false)
        }
        return rows.isEmpty ? nil : ComparisonCategory(name: category.name, rows: rows)
    }
}

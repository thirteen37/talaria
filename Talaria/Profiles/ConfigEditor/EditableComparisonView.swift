import HermesKit
import SwiftUI

/// Two-column **editable** comparison of two profiles' configs. Both columns are
/// live structured editors (`ConfigFieldControl`), each bound to its own
/// `ConfigEditingState` with its own schema and its own Save — there is no
/// aggregate save. Rows are the union of the two profiles' fields
/// (`alignedComparison`); a side that doesn't model a key shows a read-only
/// em-dash. Comparison is structured-only and desktop-only (Compare is hidden on
/// iPhone), so hover-revealed copy affordances are always available.
struct EditableComparisonView: View {
    let source: ConfigEditingState
    let dest: ConfigEditingState
    /// Visual-only row filter: when on, rows whose loaded values match on both
    /// sides are hidden (see `isDifferent` for why the loaded baseline, not the
    /// live edit, drives the filter). Never touches `working`/dirty/save — purely
    /// which rows render (see `differingCategories`).
    let showDifferencesOnly: Bool
    /// When true, a copy-across immediately `save()`s the target (push-on-copy),
    /// rather than just staging the value for the column's Save button. The
    /// cross-profile sync surface sets this; the config editor leaves it false.
    var immediateCopy = false
    /// When false, the reverse (dest → source) copy arrow is hidden — the
    /// cross-profile sync surface is one-way (default is the source of truth), so
    /// it never writes back into the source column.
    var allowReverseCopy = true
    /// Dotpaths whose copy gutter is suppressed (rendered read-only), keyed by the
    /// row's `key`. The sync surface passes `ConfigSyncScope.isExcludedFromPush`
    /// so a per-row copy can't push a value the bulk payload deliberately excludes
    /// (e.g. the stale `auxiliary.*.base_url` per-slot override). nil ⇒ every
    /// differing row is copyable (the plain config editor).
    var copyExcluded: ((String) -> Bool)?
    /// Purely presentational key/description search — composes with
    /// `showDifferencesOnly`; only changes which rows render, never
    /// `working`/dirty/save. Ephemeral view state (resets on a compare switch).
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            columnHeader(source)
            // Width-only spacer to align the headers with the copy gutter below.
            // A definite height keeps `Color` (height-greedy by default) from
            // inflating the header to fill the view and stranding the labels at
            // the baseline — which left a large blank band above the row.
            Color.clear.frame(width: copyGutterWidth, height: 0)
            columnHeader(dest)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func columnHeader(_ state: ConfigEditingState) -> some View {
        HStack(spacing: 8) {
            Text(state.profileName)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                Task { await state.save() }
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .disabled(!state.canSave)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The profile whose dashboard is unreachable (so no form can be built), if
    /// either side has degraded — Compare can't fall back to a read-only YAML
    /// dump the way the single editor does.
    private var unreachableProfileName: String? {
        if source.dashboardUnavailable { return source.profileName }
        if dest.dashboardUnavailable { return dest.profileName }
        return nil
    }

    @ViewBuilder
    private var content: some View {
        if let sourceForm = source.form, let destForm = dest.form {
            // `searched` = search filter only (no differences filter); `categories`
            // = the fully-filtered set actually rendered. Keeping both lets the
            // empty state tell a no-search-match apart from a no-difference result.
            let searched = filteredComparison(alignedComparison(source: sourceForm, dest: destForm), matchingSearch: searchText)
            let categories = showDifferencesOnly ? differingCategories(searched) : searched
            let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ConfigEditorNavBar(
                        searchText: $searchText,
                        sections: categories.map { .init(id: $0.name, label: $0.name.capitalized) },
                        proxy: proxy
                    )
                    Divider()
                    if categories.isEmpty, isSearching, searched.isEmpty {
                        ContentUnavailableView(
                            "No matching keys",
                            systemImage: "magnifyingglass",
                            description: Text("No config key or label matches “\(searchText)”.")
                        )
                    } else if categories.isEmpty, showDifferencesOnly {
                        // With a search active, only the *matching* subset was equal —
                        // keys outside the query may still differ, so scope the copy to
                        // the query rather than claiming the whole config matches.
                        ContentUnavailableView(
                            "No differences",
                            systemImage: "equal.circle",
                            description: Text(isSearching
                                ? "The keys matching “\(searchText)” are identical in both profiles."
                                : "The two profiles' configs match on every field.")
                        )
                    } else {
                        List {
                            ForEach(categories) { category in
                                Section(category.name.capitalized) {
                                    ForEach(category.rows) { row in
                                        ComparisonRowView(
                                            row: row,
                                            source: source,
                                            dest: dest,
                                            immediateCopy: immediateCopy,
                                            allowReverseCopy: allowReverseCopy,
                                            copyDisabled: copyExcluded?(row.key) ?? false
                                        )
                                    }
                                }
                                .id(category.name)
                            }
                        }
                        #if os(macOS)
                        .listStyle(.inset)
                        #else
                        .listStyle(.insetGrouped)
                        #endif
                    }
                }
            }
        } else if let unreachable = unreachableProfileName {
            ContentUnavailableView(
                "Comparison unavailable",
                systemImage: "rectangle.on.rectangle.slash",
                description: Text("The dashboard for \(unreachable) is unreachable, so its config can't be compared.")
            )
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Keeps only differing rows (per `isDifferent`), dropping empty categories so
    /// the list never shows a header with no rows. Purely presentational — the
    /// full union still backs each side's editing state.
    private func differingCategories(_ categories: [ComparisonCategory]) -> [ComparisonCategory] {
        categories.compactMap { category in
            let rows = category.rows.filter(isDifferent)
            return rows.isEmpty ? nil : ComparisonCategory(name: category.name, rows: rows)
        }
    }

    /// A row differs when either side lacks the key (one-sided rows are always a
    /// difference) or the two sides' **loaded** values aren't equal. Compares
    /// `originalValue` rather than the live `working` value on purpose: reading
    /// `working` here would make the whole comparison body re-evaluate (and
    /// re-run the union diff) on every keystroke, and would yank a row out from
    /// under an in-progress edit the instant the two sides matched. The filter
    /// therefore reflects the last load/save baseline, refreshing when a save
    /// reloads it.
    private func isDifferent(_ row: ComparisonRow) -> Bool {
        guard let sourceField = row.sourceField, let destField = row.destField else { return true }
        return source.originalValue(for: sourceField) != dest.originalValue(for: destField)
    }
}

private let copyGutterWidth: CGFloat = 36

/// One unioned key rendered as two live controls with a hover-revealed
/// copy-across gutter between them.
private struct ComparisonRowView: View {
    let row: ComparisonRow
    let source: ConfigEditingState
    let dest: ConfigEditingState
    var immediateCopy = false
    var allowReverseCopy = true
    /// When true, the copy gutter is replaced by a read-only marker — the row
    /// still shows the difference but can't be pushed (it's excluded from the
    /// sync payload). See ``EditableComparisonView/copyExcluded``.
    var copyDisabled = false

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // One shared label per row (the field title), instead of repeating
            // it inside each column's control. The dotpath sits beneath it.
            if let label = sharedLabel {
                Text(label)
                    .font(.callout)
            }
            Text(row.key)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
            HStack(alignment: .top, spacing: 8) {
                column(field: row.sourceField, state: source)
                copyGutter
                column(field: row.destField, state: dest)
            }
        }
        .padding(.vertical, 2)
        .onHover { hovering = $0 }
    }

    /// The field title shown once above both columns. Both sides model the same
    /// key, so either side's field yields the same label; the present side wins
    /// for one-sided rows. The redundant "Category → " prefix is stripped — the
    /// rows are already grouped under that category's section heading.
    private var sharedLabel: String? {
        guard let field = row.sourceField ?? row.destField else { return nil }
        return Self.stripCategoryPrefix(ConfigFieldControl.label(for: field), category: field.category)
    }

    /// Drops a leading "Category → " (or "Category -> ") from `label` when the
    /// prefix matches this row's `category`, since the section heading already
    /// shows it. Deeper paths (e.g. "Auxiliary → Fast → Model") keep everything
    /// after the first, redundant segment.
    private static func stripCategoryPrefix(_ label: String, category: String) -> String {
        guard let separator = [" → ", " -> "]
            .compactMap({ label.range(of: $0) })
            .min(by: { $0.lowerBound < $1.lowerBound })
        else { return label }
        func normalize(_ s: Substring) -> String {
            s.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "")
        }
        let prefix = label[label.startIndex..<separator.lowerBound]
        guard normalize(prefix) == normalize(Substring(category)) else { return label }
        return String(label[separator.upperBound...])
    }

    @ViewBuilder
    private func column(field: ConfigFormField?, state: ConfigEditingState) -> some View {
        if let field {
            ConfigFieldControl(state: state, field: field, showsLabel: false)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // No schema/type on this side to synthesize a control — read-only
            // placeholder (additive copy onto a side that lacks the key is out of
            // scope for v1).
            Text("—")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Copy buttons appear only when **both** sides model the key (so there is a
    /// typed setter to copy into) and the values currently differ. Reading the
    /// live values is gated on `hovering` so a keystroke only invalidates the one
    /// row being hovered — keeping the full two-column form's scroll/keystroke
    /// path off `working`.
    @ViewBuilder
    private var copyGutter: some View {
        VStack(spacing: 2) {
            if copyDisabled, row.sourceField != nil, row.destField != nil {
                // Excluded from sync (e.g. a stale per-slot `auxiliary.*.base_url`
                // override): show the difference but never offer to copy it.
                // Static — reads no live value, so it stays off the keystroke path.
                Image(systemName: "lock")
                    .foregroundStyle(.tertiary)
                    .help("Read-only — excluded from sync (a stale per-slot override).")
            } else if hovering, let sourceField = row.sourceField, let destField = row.destField {
                let sourceValue = source.value(for: sourceField)
                let destValue = dest.value(for: destField)
                if sourceValue != destValue {
                    Button {
                        dest.copyValue(sourceValue, into: destField)
                        if immediateCopy { Task { await dest.save() } }
                    } label: {
                        Image(systemName: "arrow.right")
                    }
                    .help(immediateCopy
                        ? "Copy \(source.profileName) → \(dest.profileName) (saves immediately)"
                        : "Copy \(source.profileName) → \(dest.profileName)")
                    if allowReverseCopy {
                        Button {
                            source.copyValue(destValue, into: sourceField)
                            if immediateCopy { Task { await source.save() } }
                        } label: {
                            Image(systemName: "arrow.left")
                        }
                        .help("Copy \(dest.profileName) → \(source.profileName)")
                    }
                }
            }
        }
        .buttonStyle(.borderless)
        .imageScale(.small)
        .frame(width: copyGutterWidth)
    }
}

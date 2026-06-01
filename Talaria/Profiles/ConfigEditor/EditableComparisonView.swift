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
    /// which rows render (see `visibleCategories`).
    let showDifferencesOnly: Bool

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
            let categories = visibleCategories(source: sourceForm, dest: destForm)
            if categories.isEmpty, showDifferencesOnly {
                ContentUnavailableView(
                    "No differences",
                    systemImage: "equal.circle",
                    description: Text("The two profiles' configs match on every field.")
                )
            } else {
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        if categories.count > 1 {
                            jumpBar(categories, proxy: proxy)
                            Divider()
                        }
                        List {
                            ForEach(categories) { category in
                                Section(category.name.capitalized) {
                                    ForEach(category.rows) { row in
                                        ComparisonRowView(row: row, source: source, dest: dest)
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

    /// Section dropdown that scroll-anchors the comparison list to a chosen
    /// category — mirrors the single structured editor's jump bar so the
    /// many-category union stays navigable.
    @ViewBuilder
    private func jumpBar(_ categories: [ComparisonCategory], proxy: ScrollViewProxy) -> some View {
        HStack {
            Menu {
                ForEach(categories) { category in
                    Button(category.name.capitalized) {
                        withAnimation { proxy.scrollTo(category.name, anchor: .top) }
                    }
                }
            } label: {
                Label("Jump to section", systemImage: "list.bullet.indent")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// The aligned categories to render, filtered to differing rows when
    /// `showDifferencesOnly` is on. Empty categories drop out so the list never
    /// shows a header with no rows. This is purely presentational — the full
    /// union still backs each side's editing state.
    private func visibleCategories(source sourceForm: ProfileConfigForm, dest destForm: ProfileConfigForm) -> [ComparisonCategory] {
        let categories = alignedComparison(source: sourceForm, dest: destForm)
        guard showDifferencesOnly else { return categories }
        return categories.compactMap { category in
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

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
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

    @ViewBuilder
    private func column(field: ConfigFormField?, state: ConfigEditingState) -> some View {
        if let field {
            ConfigFieldControl(state: state, field: field)
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
            if hovering, let sourceField = row.sourceField, let destField = row.destField {
                let sourceValue = source.value(for: sourceField)
                let destValue = dest.value(for: destField)
                if sourceValue != destValue {
                    Button {
                        dest.copyValue(sourceValue, into: destField)
                    } label: {
                        Image(systemName: "arrow.right")
                    }
                    .help("Copy \(source.profileName) → \(dest.profileName)")
                    Button {
                        source.copyValue(destValue, into: sourceField)
                    } label: {
                        Image(systemName: "arrow.left")
                    }
                    .help("Copy \(dest.profileName) → \(source.profileName)")
                }
            }
        }
        .buttonStyle(.borderless)
        .imageScale(.small)
        .frame(width: copyGutterWidth)
    }
}

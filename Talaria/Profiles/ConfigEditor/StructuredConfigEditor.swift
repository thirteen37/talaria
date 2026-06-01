import HermesKit
import SwiftUI

/// Schema-driven form for one profile's config. Each field renders the control
/// its schema type implies (via `ConfigFieldControl`); a section "Jump to"
/// dropdown scrolls the stacked sections so the ~100-field form stays navigable.
struct StructuredConfigEditor: View {
    let state: ConfigEditingState
    /// Purely presentational key/description search — filters which rows render
    /// (like the comparison editor's "differences only"), never touching
    /// `working`/dirty/save. Ephemeral view state: resetting on a profile switch
    /// is acceptable.
    @State private var searchText = ""

    var body: some View {
        if let form = state.form {
            let visible = form.categories(matchingSearch: searchText)
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ConfigEditorNavBar(
                        searchText: $searchText,
                        sections: visible.map { .init(id: $0.name, label: $0.name.capitalized) },
                        proxy: proxy
                    )
                    Divider()
                    if visible.isEmpty {
                        ContentUnavailableView(
                            "No matching keys",
                            systemImage: "magnifyingglass",
                            description: Text("No config key or label matches “\(searchText)”.")
                        )
                    } else {
                        // A `List` (not `Form`) so rows virtualize on macOS — the full
                        // Hermes schema is ~100 fields and a non-lazy `Form` lays them
                        // all out at once, which makes scrolling lag. Section ids let
                        // the jump dropdown scroll-anchor to a chosen segment (the
                        // nav bar's two-pass scroll keeps the anchor accurate).
                        List {
                            ForEach(visible) { category in
                                Section(category.name.capitalized) {
                                    ForEach(category.fields) { field in
                                        row(for: field)
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
        } else {
            ContentUnavailableView(
                "No editable fields",
                systemImage: "slider.horizontal.3",
                description: Text("The dashboard didn't return a config schema.")
            )
        }
    }

    @ViewBuilder
    private func row(for field: ConfigFormField) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ConfigFieldControl(state: state, field: field)
            if let description = field.schema?.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(field.key)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

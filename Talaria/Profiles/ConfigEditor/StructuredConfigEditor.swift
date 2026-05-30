import HermesKit
import SwiftUI

/// Schema-driven form for one profile's config. Each field renders the control
/// its schema type implies (via `ConfigFieldControl`); a section "Jump to"
/// dropdown scrolls the stacked sections so the ~100-field form stays navigable.
struct StructuredConfigEditor: View {
    let state: ConfigEditingState

    var body: some View {
        if let form = state.form {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    if form.categories.count > 1 {
                        jumpBar(form, proxy: proxy)
                        Divider()
                    }
                    // A `List` (not `Form`) so rows virtualize on macOS — the full
                    // Hermes schema is ~100 fields and a non-lazy `Form` lays them
                    // all out at once, which makes scrolling lag. Section ids let
                    // the jump dropdown scroll-anchor to a chosen segment (anchor
                    // precision is a known-acceptable rough edge with `List`).
                    List {
                        ForEach(form.categories) { category in
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
        } else {
            ContentUnavailableView(
                "No editable fields",
                systemImage: "slider.horizontal.3",
                description: Text("The dashboard didn't return a config schema.")
            )
        }
    }

    @ViewBuilder
    private func jumpBar(_ form: ProfileConfigForm, proxy: ScrollViewProxy) -> some View {
        HStack {
            Menu {
                ForEach(form.categories) { category in
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

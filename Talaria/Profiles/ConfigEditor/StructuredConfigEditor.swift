import HermesKit
import SwiftUI

/// Schema-driven form for one profile's config. Each field renders the control
/// its schema type implies (text / picker / stepper / toggle / list); unmodeled
/// `other` keys fall back to a type inferred from their value, and anything that
/// can't be edited safely (nested objects) renders read-only.
struct StructuredConfigEditor: View {
    let harness: ConfigEditorHarness

    var body: some View {
        if let form = harness.form {
            // A `List` (not `Form`) so rows virtualize on macOS — the full Hermes
            // schema is ~100 fields and a non-lazy `Form` lays them all out at
            // once, which makes scrolling lag.
            List {
                ForEach(form.categories) { category in
                    Section(category.name.capitalized) {
                        ForEach(category.fields) { field in
                            row(for: field)
                        }
                    }
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            #else
            .listStyle(.insetGrouped)
            #endif
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
            control(for: field)
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

    private func title(_ field: ConfigFormField) -> String {
        if let description = field.schema?.description, !description.isEmpty {
            return description
        }
        return field.key
    }

    @ViewBuilder
    private func control(for field: ConfigFormField) -> some View {
        switch effectiveType(field) {
        case .string:
            LabeledContent(title(field)) {
                TextField("", text: harness.stringBinding(for: field))
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
            }
        case .select:
            Picker(title(field), selection: harness.stringBinding(for: field)) {
                let current = harness.stringBinding(for: field).wrappedValue
                let options = field.schema?.options ?? []
                ForEach(options, id: \.self) { Text($0.isEmpty ? "(none)" : $0).tag($0) }
                // A value the option list doesn't know about survives as a
                // custom, selectable entry rather than silently resetting.
                if !current.isEmpty, !options.contains(current) {
                    Text("\(current) (custom)").tag(current)
                }
            }
        case .number:
            LabeledContent(title(field)) {
                HStack(spacing: 6) {
                    TextField("", text: harness.numberTextBinding(for: field))
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 140)
                    Stepper("", value: harness.numberBinding(for: field), step: 1)
                        .labelsHidden()
                }
            }
        case .boolean:
            Toggle(title(field), isOn: harness.boolBinding(for: field))
        case .list:
            ListFieldEditor(title: title(field), items: harness.listBinding(for: field))
        }
    }

    /// The control class to render. Schema-described fields use their declared
    /// type; `other` fields infer from the value's type. Reads the form's
    /// build-time value (`field.value`) rather than the live `working` config —
    /// a field's *type* never changes while editing, so this keeps row layout
    /// off the per-keystroke `working` dependency.
    private func effectiveType(_ field: ConfigFormField) -> ConfigFieldType {
        if let type = field.schema?.type { return type }
        switch field.value {
        case .bool: return .boolean
        case .number: return .number
        case .list: return .list
        case .string, .missing, .raw: return .string
        }
    }
}

/// Inline add/remove editor for a list-typed field.
private struct ListFieldEditor: View {
    let title: String
    @Binding var items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            ForEach(items.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    TextField("Value", text: Binding(
                        get: { index < items.count ? items[index] : "" },
                        set: { if index < items.count { items[index] = $0 } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        if index < items.count { items.remove(at: index) }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
            }
            Button {
                items.append("")
            } label: {
                Label("Add", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }
}

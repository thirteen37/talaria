import HermesKit
import SwiftUI

/// The editable control for one config field, bound to a `ConfigEditingState`.
/// Shared by the single-profile structured editor and each column of the
/// editable comparison so both render identical controls (text / picker /
/// stepper / toggle / list).
///
/// The control class is decided from the passed-in `field.value` — the form's
/// build-time value — never from the live `working` config. A field's *type*
/// doesn't change while editing, so keeping the decision off `working` keeps row
/// layout out of the per-keystroke invalidation path.
struct ConfigFieldControl: View {
    let state: ConfigEditingState
    let field: ConfigFormField

    var body: some View {
        switch effectiveType {
        case .string:
            LabeledContent(title) {
                TextField("", text: state.stringBinding(for: field))
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .clearButton(state.stringBinding(for: field))
            }
        case .select:
            Picker(title, selection: state.stringBinding(for: field)) {
                let current = state.stringBinding(for: field).wrappedValue
                let options = field.schema?.options ?? []
                ForEach(options, id: \.self) { Text($0.isEmpty ? "(none)" : $0).tag($0) }
                // Any current value the option list doesn't include — a custom
                // entry, or the empty string for a key the config omits — gets a
                // matching tag so the Picker has a valid selection (otherwise
                // SwiftUI logs "no associated tag" and shows nothing selected).
                if !options.contains(current) {
                    Text(current.isEmpty ? "(none)" : "\(current) (custom)").tag(current)
                }
            }
        case .number:
            LabeledContent(title) {
                HStack(spacing: 6) {
                    // No clear button: a number key has no meaningful empty
                    // state in the structured editor. Setting "" would store
                    // .string(""), which ProfileConfigForm.edits drops for a
                    // number-typed key (see editsDropsInvalidNumberInput), so the
                    // old value silently returns on save. Removal is the YAML
                    // pane's job — the structured path is additive by design.
                    TextField("", text: state.numberTextBinding(for: field))
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 140)
                    Stepper("", value: state.numberBinding(for: field), step: 1)
                        .labelsHidden()
                }
            }
        case .boolean:
            Toggle(title, isOn: state.boolBinding(for: field))
        case .list:
            ListFieldEditor(title: title, items: state.listBinding(for: field))
        }
    }

    private var title: String {
        if let description = field.schema?.description, !description.isEmpty {
            return description
        }
        return field.key
    }

    /// The control class to render. Schema-described fields use their declared
    /// type; `other` fields infer from the value's type.
    private var effectiveType: ConfigFieldType {
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
struct ListFieldEditor: View {
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

private extension View {
    /// Appends a trailing clear button shown only when `text` is non-empty,
    /// mirroring the macOS search-field affordance. Resets the bound string to "".
    func clearButton(_ text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            self
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear")
                .help("Clear the value")
            }
        }
    }
}

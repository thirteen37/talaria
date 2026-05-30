import SwiftUI

/// Raw YAML view of the same edited config. Editable when a dashboard is
/// connected (Save PUTs the parsed document); read-only when the editor is in
/// its degraded, dashboard-unavailable state. Parse errors surface inline and
/// block Save without discarding the user's text.
struct YAMLConfigEditor: View {
    let harness: ConfigEditorHarness

    var body: some View {
        VStack(spacing: 0) {
            if let error = harness.yamlParseError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.orange.opacity(0.12))
            }

            if harness.dashboardUnavailable {
                // Read-only on-disk config: no dashboard to write back to.
                ScrollView {
                    Text(harness.yamlText.isEmpty ? "No config available." : harness.yamlText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
            } else {
                TextEditor(text: Binding(
                    get: { harness.yamlText },
                    set: { harness.yamlText = $0; harness.yamlChanged() }
                ))
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .padding(4)
            }
        }
    }
}

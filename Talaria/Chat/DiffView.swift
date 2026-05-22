import HermesKit
import SwiftUI

struct DiffView: View {
    let diff: Diff

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(diff.path, systemImage: "doc.text")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    DiffColumn(title: "Before", text: diff.oldText ?? "", placeholder: diff.oldText == nil ? "New file" : "")
                    Divider()
                    DiffColumn(title: "After", text: diff.newText, placeholder: "")
                }
                .frame(minWidth: 620, alignment: .leading)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct DiffColumn: View {
    let title: String
    let text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            if text.isEmpty, !placeholder.isEmpty {
                Text(placeholder)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
            } else {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
            }
        }
        .padding(8)
        .frame(width: 310, alignment: .topLeading)
    }
}

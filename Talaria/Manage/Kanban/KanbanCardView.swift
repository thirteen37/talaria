import HermesKit
import SwiftUI

/// One card cell on the board. Draggable (for the column drag-and-drop move) and
/// tappable (selects the task into the detail pane). Kept presentational — all
/// state and actions live on `KanbanHarness`.
struct KanbanCardView: View {
    let card: KanbanCard
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(card.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if let priority = card.priority, priority != 0 {
                        priorityBadge(priority)
                    }
                }
                if let assignee = card.assignee, !assignee.isEmpty {
                    Label(assignee, systemImage: "person")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
                metaRow
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                                  lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .draggable(KanbanCardTransfer(taskID: card.id, sourceStatus: card.status)) {
            // Drag preview — a compact title chip.
            Text(card.title)
                .font(.callout)
                .lineLimit(1)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private var metaRow: some View {
        let chips = metaChips
        if !chips.isEmpty {
            HStack(spacing: 8) {
                ForEach(chips, id: \.self) { chip in
                    Label(chip.text, systemImage: chip.symbol)
                        .font(.caption2)
                        .foregroundStyle(chip.tint)
                        .labelStyle(.titleAndIcon)
                }
            }
        }
    }

    private struct MetaChip: Hashable {
        let symbol: String
        let text: String
        let tintIsWarning: Bool
        var tint: Color { tintIsWarning ? .orange : .secondary }
    }

    private var metaChips: [MetaChip] {
        var chips: [MetaChip] = []
        if let count = card.commentCount, count > 0 {
            chips.append(MetaChip(symbol: "text.bubble", text: "\(count)", tintIsWarning: false))
        }
        let links = (card.linkCounts?.parents ?? 0) + (card.linkCounts?.children ?? 0)
        if links > 0 {
            chips.append(MetaChip(symbol: "link", text: "\(links)", tintIsWarning: false))
        }
        if let progress = card.progress, let total = progress.total, total > 0 {
            chips.append(MetaChip(symbol: "checklist", text: "\(progress.done ?? 0)/\(total)", tintIsWarning: false))
        }
        if let warnings = card.warnings, let count = warnings.count, count > 0 {
            chips.append(MetaChip(symbol: "exclamationmark.triangle", text: "\(count)", tintIsWarning: true))
        }
        if let diagnostics = card.diagnostics, !diagnostics.isEmpty {
            chips.append(MetaChip(symbol: "stethoscope", text: "\(diagnostics.count)", tintIsWarning: true))
        }
        return chips
    }

    private func priorityBadge(_ priority: Int) -> some View {
        Text("P\(priority)")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(priority > 0 ? Color.orange.opacity(0.18) : Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(priority > 0 ? Color.orange : Color.secondary)
    }
}

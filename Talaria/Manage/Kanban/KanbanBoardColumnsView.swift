import HermesKit
import SwiftUI

/// Humanizes a status/column slug for display (`"in_review"` → `"In Review"`).
func kanbanStatusTitle(_ status: String) -> String {
    status
        .split(whereSeparator: { $0 == "_" || $0 == "-" })
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}

/// The board surface. On macOS/iPad it's a horizontally-scrolling row of
/// drop-target columns; on iPhone it degrades to a status-segmented vertical
/// list with a per-card "Move to" menu (drag-and-drop across off-screen columns
/// is impractical on a phone). Both share the harness, so only the gesture
/// differs.
struct KanbanBoardColumnsView: View {
    let harness: KanbanHarness

    var body: some View {
        if Idiom.isPhone {
            KanbanPhoneBoard(harness: harness)
        } else {
            KanbanWideBoard(harness: harness)
        }
    }
}

// MARK: - macOS / iPad

private struct KanbanWideBoard: View {
    let harness: KanbanHarness

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(harness.board?.columns ?? []) { column in
                    KanbanColumnView(harness: harness, column: column)
                        .frame(width: 280)
                }
            }
            .padding(12)
        }
        .overlay {
            if let board = harness.board, board.columns.allSatisfy(\.tasks.isEmpty), !harness.isLoading {
                ContentUnavailableView("No tasks", systemImage: "rectangle.split.3x1")
            }
        }
    }
}

private struct KanbanColumnView: View {
    let harness: KanbanHarness
    let column: KanbanColumn

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(kanbanStatusTitle(column.name))
                    .font(.headline)
                Spacer()
                Text("\(column.tasks.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            .padding(.horizontal, 4)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(column.tasks) { card in
                        KanbanCardView(
                            card: card,
                            isSelected: harness.selectedTaskID == card.id,
                            onSelect: { harness.selectTask(card.id) }
                        )
                    }
                }
                .padding(2)
            }
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .dropDestination(for: KanbanCardTransfer.self) { items, _ in
            guard let item = items.first, item.sourceStatus != column.name else { return false }
            Task { await harness.moveCard(id: item.taskID, from: item.sourceStatus, to: column.name) }
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

// MARK: - iPhone

private struct KanbanPhoneBoard: View {
    let harness: KanbanHarness
    @State private var selectedStatus: String = kanbanStatusOrder.first ?? "triage"

    private var columns: [KanbanColumn] { harness.board?.columns ?? [] }

    private var currentColumn: KanbanColumn? {
        columns.first { $0.name == selectedStatus }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Status", selection: $selectedStatus) {
                ForEach(columns) { column in
                    Text("\(kanbanStatusTitle(column.name)) (\(column.tasks.count))").tag(column.name)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal)
            .padding(.vertical, 8)

            List {
                ForEach(currentColumn?.tasks ?? []) { card in
                    Button { harness.selectTask(card.id) } label: {
                        KanbanCardRow(card: card)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        moveMenuActions(for: card)
                    }
                    .contextMenu {
                        moveMenu(for: card)
                    }
                }
            }
            .overlay {
                if (currentColumn?.tasks.isEmpty ?? true), !harness.isLoading {
                    ContentUnavailableView("No tasks", systemImage: "rectangle.split.3x1")
                }
            }
        }
        .onChange(of: columns.map(\.name)) { _, names in
            if !names.contains(selectedStatus), let first = names.first {
                selectedStatus = first
            }
        }
    }

    @ViewBuilder
    private func moveMenu(for card: KanbanCard) -> some View {
        Menu("Move to") {
            ForEach(targetStatuses(for: card), id: \.self) { status in
                Button(kanbanStatusTitle(status)) {
                    Task { await harness.moveCard(id: card.id, from: card.status, to: status) }
                }
            }
        }
    }

    @ViewBuilder
    private func moveMenuActions(for card: KanbanCard) -> some View {
        ForEach(targetStatuses(for: card).prefix(3), id: \.self) { status in
            Button(kanbanStatusTitle(status)) {
                Task { await harness.moveCard(id: card.id, from: card.status, to: status) }
            }
        }
    }

    private func targetStatuses(for card: KanbanCard) -> [String] {
        columns.map(\.name).filter { $0 != card.status }
    }
}

/// Compact card layout for the iPhone list rows.
private struct KanbanCardRow: View {
    let card: KanbanCard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.title).font(.body).lineLimit(2)
            HStack(spacing: 10) {
                if let assignee = card.assignee, !assignee.isEmpty {
                    Label(assignee, systemImage: "person").labelStyle(.titleAndIcon)
                }
                if let priority = card.priority, priority != 0 {
                    Text("P\(priority)")
                }
                if let count = card.commentCount, count > 0 {
                    Label("\(count)", systemImage: "text.bubble").labelStyle(.titleAndIcon)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

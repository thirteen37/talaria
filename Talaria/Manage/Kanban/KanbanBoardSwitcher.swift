import HermesKit
import SwiftUI

/// Toolbar menu listing the boards (checkmark on the current one) with a
/// "Manage boards…" entry that opens the management sheet.
struct KanbanBoardMenu: View {
    let harness: KanbanHarness
    @Binding var showManageSheet: Bool

    private var currentSlug: String? {
        harness.selectedBoardSlug ?? harness.boards.first(where: { $0.isCurrent == true })?.slug
    }

    private var currentTitle: String {
        guard let slug = currentSlug else { return "Board" }
        let board = harness.boards.first { $0.slug == slug }
        return board?.name ?? slug
    }

    var body: some View {
        Menu {
            ForEach(harness.boards) { board in
                Button {
                    Task { await harness.switchBoard(slug: board.slug) }
                } label: {
                    if board.slug == currentSlug {
                        Label(board.name ?? board.slug, systemImage: "checkmark")
                    } else {
                        Text(board.name ?? board.slug)
                    }
                }
            }
            if !harness.boards.isEmpty { Divider() }
            Button {
                showManageSheet = true
            } label: {
                Label("Manage boards…", systemImage: "slider.horizontal.3")
            }
        } label: {
            Label(currentTitle, systemImage: "rectangle.split.3x1")
        }
        .help("Switch or manage boards")
    }
}

/// Board management sheet — create / rename / delete, mirroring the desktop
/// Profiles control strip. Every control carries a `.help`.
struct KanbanBoardManageSheet: View {
    let harness: KanbanHarness
    @Environment(\.dismiss) private var dismiss

    @State private var selection: String?
    @State private var draft: BoardDraft?
    @State private var boardToDelete: KanbanBoardSummary?

    private struct BoardDraft: Equatable {
        enum Mode: Equatable { case create, rename(slug: String) }
        var mode: Mode
        var slug: String = ""
        var name: String = ""
    }

    private var selectedBoard: KanbanBoardSummary? {
        harness.boards.first { $0.slug == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage Boards").font(.headline)

            List(selection: $selection) {
                ForEach(harness.boards) { board in
                    HStack {
                        Text(board.name ?? board.slug)
                        if board.isCurrent == true {
                            Text("current")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                        Spacer()
                        Text(board.slug).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .tag(board.slug)
                }
            }
            .frame(minHeight: 160)

            controlStrip

            if let draft {
                editor(draft)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 380, minHeight: 360)
        .alert(
            "Delete board?",
            isPresented: Binding(get: { boardToDelete != nil }, set: { if !$0 { boardToDelete = nil } }),
            presenting: boardToDelete
        ) { board in
            Button("Delete", role: .destructive) {
                Task { await harness.deleteBoard(slug: board.slug) }
            }
            Button("Cancel", role: .cancel) { boardToDelete = nil }
        } message: { board in
            Text("“\(board.name ?? board.slug)” and its tasks will be removed.")
        }
    }

    private var controlStrip: some View {
        HStack(spacing: 8) {
            Button {
                draft = BoardDraft(mode: .create)
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Create a new board")
            Button {
                guard let board = selectedBoard else { return }
                draft = BoardDraft(mode: .rename(slug: board.slug), name: board.name ?? board.slug)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .disabled(selectedBoard == nil)
            .help("Rename the selected board")
            Button(role: .destructive) {
                boardToDelete = selectedBoard
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selectedBoard == nil)
            .help("Delete the selected board")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func editor(_ draft: BoardDraft) -> some View {
        let binding = Binding(get: { self.draft ?? draft }, set: { self.draft = $0 })
        Form {
            switch draft.mode {
            case .create:
                Section("New board") {
                    TextField("Slug (e.g. ops)", text: binding.slug)
                        .font(.system(.body, design: .monospaced))
                    TextField("Name (optional)", text: binding.name)
                }
            case .rename:
                Section("Rename board") {
                    TextField("Name", text: binding.name)
                }
            }
            HStack {
                Button("Cancel", role: .cancel) { self.draft = nil }
                Spacer()
                Button("Save") { commit(binding.wrappedValue) }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(saveDisabled(binding.wrappedValue))
            }
        }
    }

    private func saveDisabled(_ draft: BoardDraft) -> Bool {
        switch draft.mode {
        case .create:
            return draft.slug.trimmingCharacters(in: .whitespaces).isEmpty
        case .rename:
            return draft.name.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func commit(_ draft: BoardDraft) {
        switch draft.mode {
        case .create:
            let slug = draft.slug.trimmingCharacters(in: .whitespaces)
            let name = draft.name.trimmingCharacters(in: .whitespaces)
            Task { await harness.createBoard(slug: slug, name: name.isEmpty ? nil : name, switchTo: false) }
        case let .rename(slug):
            let name = draft.name.trimmingCharacters(in: .whitespaces)
            Task { await harness.renameBoard(slug: slug, name: name) }
        }
        self.draft = nil
    }
}

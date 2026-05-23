import HermesKit
import SwiftUI

struct SessionsSidebar: View {
    @Bindable var store: SessionsStore

    @State private var renameTarget: SessionsStore.OpenSession?
    @State private var renameText: String = ""

    var body: some View {
        Section("Chat") {
            ForEach(store.openSessions) { session in
                row(for: session)
            }

            Button {
                Task { await store.openNew() }
            } label: {
                Label("New session", systemImage: "plus")
            }
        }
        .sheet(item: $renameTarget) { target in
            renameSheet(for: target)
        }
    }

    @ViewBuilder
    private func row(for session: SessionsStore.OpenSession) -> some View {
        Button {
            store.selection = session.id
        } label: {
            HStack(spacing: 8) {
                statusDot(for: session.id)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title ?? shortId(session.id))
                        .lineLimit(1)
                    Text((session.cwd as NSString).lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(store.selection == session.id ? Color.accentColor.opacity(0.15) : Color.clear)
        .contextMenu {
            Button("Rename…") {
                renameTarget = session
                renameText = session.title ?? ""
            }
            Button("Close tab") {
                Task { await store.closeTab(session.id) }
            }
            Divider()
            Button("Delete session", role: .destructive) {
                Task { await store.deleteSession(session.id) }
            }
        }
    }

    private func statusDot(for id: SessionId) -> some View {
        let status = store.statuses[id] ?? .idle
        let color: Color
        switch status {
        case .idle: color = .secondary
        case .working: color = .green
        case .error: color = .red
        }
        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private func shortId(_ id: SessionId) -> String {
        SessionIdFormatter.short(id)
    }

    private func renameSheet(for target: SessionsStore.OpenSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename session").font(.headline)
            TextField("Title", text: $renameText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") {
                    renameTarget = nil
                }
                Button("Save") {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let id = target.id
                    renameTarget = nil
                    guard !trimmed.isEmpty else {
                        return
                    }
                    Task { await store.renameSession(id, to: trimmed) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
    }
}

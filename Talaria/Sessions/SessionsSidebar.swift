import HermesKit
import SwiftUI

struct SessionsSidebar: View {
    @Bindable var store: SessionsStore
    let snapshot: RemoteSnapshot?

    @State private var renameTarget: SessionsStore.OpenSession?
    @State private var renameText: String = ""
    @State private var snapshotState: SnapshotState = .missing
    @State private var snapshotTask: Task<Void, Never>?

    init(store: SessionsStore, snapshot: RemoteSnapshot? = nil) {
        self.store = store
        self.snapshot = snapshot
    }

    var body: some View {
        Group {
            if snapshot != nil {
                Section {
                    SnapshotBadge(state: snapshotState, refresh: { refreshSnapshot() })
                }
            }

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
        }
        .sheet(item: $renameTarget) { target in
            renameSheet(for: target)
        }
        .task(id: snapshot?.profile.id) {
            guard let snapshot else { return }
            snapshotState = await snapshot.currentState()
            snapshotTask?.cancel()
            snapshotTask = Task { @MainActor [weak store] in
                for await state in await snapshot.subscribe() {
                    snapshotState = state
                    if case .fresh = state {
                        store?.browserRefreshToken &+= 1
                    }
                }
            }
            // First time we open a remote window with no cached snapshot,
            // kick off a fetch so the sidebar isn't empty.
            if case .missing = snapshotState {
                await fetchSnapshot()
            }
        }
        .onDisappear {
            snapshotTask?.cancel()
            snapshotTask = nil
        }
    }

    private func refreshSnapshot() {
        Task { await fetchSnapshot() }
    }

    private func fetchSnapshot() async {
        guard let snapshot else { return }
        do {
            try await snapshot.refresh()
            store.browserRefreshToken &+= 1
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func row(for session: SessionsStore.OpenSession) -> some View {
        Button {
            store.selection = session.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                // The status dot is an SF Symbol inside the title text run so
                // the text layout engine aligns it to the name's optical
                // center (a sibling Circle in an HStack centers on the line
                // box instead, which reads low).
                (
                    Text(Image(systemName: "circle.fill"))
                        .font(.system(size: 9))
                        .foregroundColor(statusColor(for: session.id))
                    + Text("  ")
                    + Text(session.title ?? shortId(session.id))
                )
                .lineLimit(1)

                Text((session.cwd as NSString).lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // Indent under the title text (past the dot + spaces) so
                    // the subtitle lines up with the session name.
                    .padding(.leading, 17)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private func statusColor(for id: SessionId) -> Color {
        switch store.statuses[id] ?? .idle {
        case .idle: return .secondary
        case .working: return .green
        case .error: return .red
        }
    }

    private func shortId(_ id: SessionId) -> String {
        SessionIdFormatter.short(id)
    }

    private struct SnapshotBadge: View {
        let state: SnapshotState
        let refresh: () -> Void

        var body: some View {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isRefreshing)
            }
        }

        private var label: String {
            switch state {
            case .missing: return "No snapshot"
            case .refreshing: return "Refreshing…"
            case let .fresh(age): return "Snapshot \(formatAge(age))"
            case let .stale(age): return "Stale \(formatAge(age))"
            case let .error(message): return message
            }
        }

        private var color: Color {
            switch state {
            case .missing: return .gray
            case .refreshing: return .blue
            case let .fresh(age) where age < 60: return .green
            case .fresh: return .gray
            case .stale: return .yellow
            case .error: return .red
            }
        }

        private var isRefreshing: Bool {
            if case .refreshing = state { return true }
            return false
        }

        private func formatAge(_ seconds: Int) -> String {
            if seconds < 60 { return "\(seconds)s ago" }
            if seconds < 3600 { return "\(seconds / 60)m ago" }
            return "\(seconds / 3600)h ago"
        }
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

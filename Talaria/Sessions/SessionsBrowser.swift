import HermesKit
import SwiftUI

struct SessionsBrowser: View {
    let store: SessionsStore
    let db: HermesDB?

    @State private var query: String = ""
    @State private var sort: HermesDBSortOrder = .updatedDescending
    @State private var sessions: [HermesSessionSummary] = []
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let db {
                content(db: db)
            } else if store.snapshot != nil {
                ContentUnavailableView(
                    "Snapshot not fetched yet",
                    systemImage: "arrow.down.circle.dotted",
                    description: Text("Pull the remote SQLite snapshot from the sidebar to browse sessions.")
                )
            } else {
                ContentUnavailableView(
                    "No Hermes sessions yet",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("~/.hermes/state.db doesn't exist. Run `hermes` once to create it, then relaunch Talaria.")
                )
            }
        }
        .navigationTitle("Sessions")
    }

    @ViewBuilder
    private func content(db: HermesDB) -> some View {
        VStack(spacing: 0) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if sessions.isEmpty && !isLoading {
                ContentUnavailableView(
                    query.isEmpty ? "No Sessions" : "No matches",
                    systemImage: "clock.arrow.circlepath"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(sessions) { summary in
                    SessionRow(summary: summary) {
                        Task { await store.openExisting(summary) }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search sessions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Sort", selection: $sort) {
                    Text("Recent").tag(HermesDBSortOrder.updatedDescending)
                    Text("Title").tag(HermesDBSortOrder.titleAscending)
                }
                .pickerStyle(.segmented)
            }
        }
        .task(id: TaskKey(query: query, sort: sort, refresh: store.browserRefreshToken)) {
            await reload(db: db)
        }
    }

    private func reload(db: HermesDB) async {
        isLoading = true
        // Only flip the indicator off when this task ran to completion. If we
        // were cancelled (rapid typing), the next .task(id:) has already set
        // isLoading = true and we'd flicker by overwriting it.
        defer {
            if !Task.isCancelled {
                isLoading = false
            }
        }

        do {
            try await Task.sleep(for: .milliseconds(150))
        } catch {
            return
        }

        do {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let results: [HermesSessionSummary]
            if trimmed.isEmpty {
                results = try await db.listSessions(sort: sort)
            } else {
                results = try await db.searchSessions(query: trimmed, sort: sort)
            }
            sessions = results
            errorMessage = nil
        } catch {
            sessions = []
            errorMessage = error.localizedDescription
        }
    }

    private struct TaskKey: Hashable {
        var query: String
        var sort: HermesDBSortOrder
        var refresh: Int
    }
}

private struct SessionRow: View {
    let summary: HermesSessionSummary
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title.isEmpty ? SessionIdFormatter.short(summary.id) : summary.title)
                    .font(.body)
                HStack(spacing: 8) {
                    if let cwd = summary.cwd {
                        Label((cwd as NSString).lastPathComponent, systemImage: "folder")
                            .labelStyle(.titleAndIcon)
                    }
                    if let updatedAt = summary.updatedAt {
                        Text(updatedAt, style: .relative)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


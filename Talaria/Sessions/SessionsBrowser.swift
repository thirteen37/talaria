import HermesKit
import SwiftUI

struct SessionsBrowser: View {
    let store: SessionsStore
    let client: DashboardClient?

    enum SortOrder: String, CaseIterable, Identifiable {
        case recent
        case title

        var id: String { rawValue }
        var label: String {
            switch self {
            case .recent: return "Recent"
            case .title: return "Title"
            }
        }
    }

    @State private var query: String = ""
    @State private var sort: SortOrder = .recent
    @State private var sessions: [HermesSessionSummary] = []
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let client {
                content(client: client)
            } else {
                ContentUnavailableView(
                    "Dashboard not ready",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("Waiting for the Hermes dashboard to come online.")
                )
            }
        }
        .navigationTitle("Sessions")
    }

    @ViewBuilder
    private func content(client: DashboardClient) -> some View {
        Group {
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
        .searchable(text: $query, prompt: "Search sessions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Sort", selection: $sort) {
                    ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .task(id: TaskKey(query: query, sort: sort, refresh: store.browserRefreshToken)) {
            await reload(client: client)
        }
    }

    private func reload(client: DashboardClient) async {
        isLoading = true
        defer {
            if !Task.isCancelled {
                isLoading = false
            }
        }

        // Small debounce so rapid typing doesn't fire a request per keystroke.
        do {
            try await Task.sleep(for: .milliseconds(150))
        } catch {
            return
        }

        do {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            var results: [HermesSessionSummary]
            if trimmed.isEmpty {
                let response = try await client.listSessions(limit: 200)
                results = response.sessions.map(HermesSessionSummary.init)
            } else {
                let response = try await client.searchSessions(query: trimmed, limit: 200)
                results = response.results.map { hit in
                    HermesSessionSummary(
                        id: hit.sessionId,
                        title: hit.displaySnippet ?? "",
                        updatedAt: hit.sessionStarted.map { Date(timeIntervalSince1970: $0) },
                        cwd: nil
                    )
                }
            }
            if sort == .title {
                results.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
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
        var sort: SortOrder
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
                    .lineLimit(2)
                if let updatedAt = summary.updatedAt {
                    Text(updatedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

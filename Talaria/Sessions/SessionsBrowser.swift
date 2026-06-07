import HermesKit
import SwiftUI

struct SessionsBrowser: View {
    let store: SessionsStore
    let client: DashboardClient?
    /// Called after a session is opened. The iOS Settings/browser sheet uses
    /// this to dismiss itself so the chat (which pushes via the selection)
    /// becomes visible. macOS shows the browser in the detail pane and leaves
    /// this nil.
    var onOpen: (() -> Void)?

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
    /// Server-reported total session count from the unfiltered browse path,
    /// shown in the header. Nil while searching (search has no total) or when an
    /// older server omits it.
    @State private var total: Int?

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
                    SessionRow(
                        summary: summary,
                        open: {
                            Task { await store.openExisting(summary) }
                            onOpen?()
                        },
                        // Resume this session as the real Hermes TUI (embedded
                        // terminal) instead of the native chat view. `nil` hides
                        // the button on platforms without TUI support (iOS);
                        // `tuiDisabled` enforces one mode per session id at a
                        // time (disabled when already open inline).
                        openTUI: store.supportsTUI ? {
                            Task { await store.openTUI(resume: summary) }
                            onOpen?()
                        } : nil,
                        tuiDisabled: store.isOpenInline(summary.id)
                    )
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.bar)
                }
                if let total {
                    Text("^[\(total) session](inflect: true)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.bar)
                }
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
                total = response.total
            } else {
                total = nil
                let response = try await client.searchSessions(query: trimmed, limit: 200)
                // `/api/sessions/search` returns one hit per matching message, so
                // a session matching in several messages appears multiple times.
                // Keep the first hit per session to give `List` stable, unique IDs.
                var seen = Set<String>()
                results = response.results.compactMap { hit in
                    guard seen.insert(hit.sessionId).inserted else { return nil }
                    return HermesSessionSummary(
                        id: hit.sessionId,
                        title: hit.displaySnippet ?? "",
                        updatedAt: hit.sessionStarted.map { Date(timeIntervalSince1970: $0) },
                        cwd: nil
                    )
                }
            }
            // Title sort is client-side over the fetched window only. The server
            // returns at most `limit` sessions recency-first, so beyond that cap
            // this reorders a recency-windowed subset rather than all sessions —
            // an older session whose title sorts first won't appear. Accurate
            // ordering past the cap needs server-side title sort or pagination.
            if sort == .title {
                results.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            }
            sessions = results
            errorMessage = nil
        } catch {
            sessions = []
            total = nil
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
    var openTUI: (() -> Void)?
    var tuiDisabled: Bool = false

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if summary.isActive {
                            Circle()
                                .fill(.green)
                                .frame(width: 7, height: 7)
                                .accessibilityLabel("Active")
                        }
                        Text(summary.title.isEmpty ? SessionIdFormatter.short(summary.id) : summary.title)
                            .font(.body)
                            .lineLimit(2)
                    }
                    if let preview = summary.preview {
                        Text(preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    metadata
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let openTUI {
                Button(action: openTUI) {
                    Image(systemName: "terminal")
                }
                .buttonStyle(.borderless)
                .disabled(tuiDisabled)
                .help(tuiDisabled
                    ? "Already open inline — close it to open as a terminal session"
                    : "Open as a terminal (TUI) session")
                .accessibilityLabel("Open as TUI")
                #if os(macOS)
                .opacity(isHovering ? 1 : 0)   // hover-reveal on macOS
                #endif
            }
        }
        #if os(macOS)
        .onHover { isHovering = $0 }
        #endif
    }

    /// Compact, secondary metadata strip under the title/preview. Identity
    /// (time, source, model) sits on the left; the numeric stats (message/tool
    /// counts, tokens, cost) are pushed to the trailing edge so the row reads as
    /// two balanced groups instead of one long left-stacked run. Every element
    /// is conditional, so the lean search-result shape (all new fields nil) and
    /// older servers render exactly the title + time as before.
    @ViewBuilder
    private var metadata: some View {
        HStack(spacing: 6) {
            if let time = summary.displayTime {
                Text(time, style: .relative)
            }
            if let source = summary.source, !source.isEmpty {
                chip(source)
            }
            if let model = summary.model, !model.isEmpty {
                chip(model)
            }

            Spacer(minLength: 12)

            if let count = summary.messageCount, count > 0 {
                Label("\(count)", systemImage: "bubble.left.and.bubble.right")
            }
            if let tools = summary.toolCallCount, tools > 0 {
                Label("\(tools)", systemImage: "wrench.and.screwdriver")
            }
            if let tokens = summary.tokenTotal, tokens > 0 {
                Text(Self.tokenLabel(tokens))
            }
            if let cost = summary.costDisplay {
                Text(cost)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
    }

    /// Compacts a token total for the chip: `1234 → "1.2K"`, `187884 → "188K"`.
    private static func tokenLabel(_ tokens: Int) -> String {
        if tokens < 1000 {
            return "\(tokens) tok"
        }
        let thousands = Double(tokens) / 1000
        if thousands < 10 {
            return String(format: "%.1fK tok", thousands)
        }
        return "\(Int(thousands.rounded()))K tok"
    }
}

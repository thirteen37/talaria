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

    /// Coarse last-activity windows for the Filter menu, applied over
    /// `summary.displayTime`.
    enum DateRange: String, CaseIterable, Identifiable {
        case any
        case today
        case last7
        case last30

        var id: String { rawValue }
        var label: String {
            switch self {
            case .any: return "Any time"
            case .today: return "Today"
            case .last7: return "Last 7 days"
            case .last30: return "Last 30 days"
            }
        }

        /// The earliest `displayTime` that passes this window, or nil for `.any`.
        var cutoff: Date? {
            let calendar = Calendar.current
            let now = Date()
            switch self {
            case .any: return nil
            case .today: return calendar.startOfDay(for: now)
            case .last7: return calendar.date(byAdding: .day, value: -7, to: now)
            case .last30: return calendar.date(byAdding: .day, value: -30, to: now)
            }
        }
    }

    /// Minimum message-count buckets for the Filter menu, applied over
    /// `summary.messageCount`. Preset (not free-text) so it lives cleanly inside
    /// the toolbar `Menu`, mirroring `DateRange`.
    enum MessageFloor: String, CaseIterable, Identifiable {
        case any
        case atLeast5
        case atLeast20
        case atLeast50

        var id: String { rawValue }
        var label: String {
            switch self {
            case .any: return "Any"
            case .atLeast5: return "≥ 5 messages"
            case .atLeast20: return "≥ 20 messages"
            case .atLeast50: return "≥ 50 messages"
            }
        }

        /// The inclusive floor, or nil for `.any`.
        var cutoff: Int? {
            switch self {
            case .any: return nil
            case .atLeast5: return 5
            case .atLeast20: return 20
            case .atLeast50: return 50
            }
        }

        /// Whether `count` clears this floor. A nil count is treated as 0, so an
        /// unknown value never satisfies a set floor.
        func passes(_ count: Int?) -> Bool {
            guard let cutoff else { return true }
            return (count ?? 0) >= cutoff
        }
    }

    /// Minimum total-token buckets for the Filter menu, over `summary.tokenTotal`.
    enum TokenFloor: String, CaseIterable, Identifiable {
        case any
        case atLeast10K
        case atLeast100K
        case atLeast1M

        var id: String { rawValue }
        var label: String {
            switch self {
            case .any: return "Any"
            case .atLeast10K: return "≥ 10K tokens"
            case .atLeast100K: return "≥ 100K tokens"
            case .atLeast1M: return "≥ 1M tokens"
            }
        }

        var cutoff: Int? {
            switch self {
            case .any: return nil
            case .atLeast10K: return 10_000
            case .atLeast100K: return 100_000
            case .atLeast1M: return 1_000_000
            }
        }

        func passes(_ tokens: Int?) -> Bool {
            guard let cutoff else { return true }
            return (tokens ?? 0) >= cutoff
        }
    }

    /// Minimum cost buckets for the Filter menu, over `summary.costUsd`. `>$0`
    /// means "spent anything"; the rest are inclusive dollar floors.
    enum CostFloor: String, CaseIterable, Identifiable {
        case any
        case aboveZero
        case atLeast1
        case atLeast10

        var id: String { rawValue }
        var label: String {
            switch self {
            case .any: return "Any"
            case .aboveZero: return "> $0"
            case .atLeast1: return "≥ $1"
            case .atLeast10: return "≥ $10"
            }
        }

        /// Whether `cost` clears this floor. A nil cost is treated as 0, so a
        /// session with no reported cost never satisfies a set floor.
        func passes(_ cost: Double?) -> Bool {
            let value = cost ?? 0
            switch self {
            case .any: return true
            case .aboveZero: return value > 0
            case .atLeast1: return value >= 1
            case .atLeast10: return value >= 10
            }
        }
    }

    /// The set of browse-list filters. Defaults are all-inclusive, so
    /// `isActive` is false until the user narrows something.
    struct Filter: Equatable {
        var source: String?
        var model: String?
        var dateRange: DateRange = .any
        var activeOnly = false
        var messageFloor: MessageFloor = .any
        var tokenFloor: TokenFloor = .any
        var costFloor: CostFloor = .any
        var hasToolCalls = false

        var isActive: Bool {
            source != nil || model != nil || dateRange != .any || activeOnly
                || messageFloor != .any || tokenFloor != .any || costFloor != .any
                || hasToolCalls
        }

        /// Pure per-row predicate: true when `summary` survives every active
        /// filter. Nil-field semantics exclude correctly — a lean search row
        /// (source/model/counts nil) fails any set source/model filter or numeric
        /// floor, which is how a search query and the filters compose. Extracted
        /// (no view state) so it's unit-testable.
        func matches(_ summary: HermesSessionSummary) -> Bool {
            if let source, summary.source != source { return false }
            if let model, summary.model != model { return false }
            if activeOnly, !summary.isActive { return false }
            if let cutoff = dateRange.cutoff {
                guard let time = summary.displayTime, time >= cutoff else { return false }
            }
            if !messageFloor.passes(summary.messageCount) { return false }
            if !tokenFloor.passes(summary.tokenTotal) { return false }
            if !costFloor.passes(summary.costUsd) { return false }
            if hasToolCalls, (summary.toolCallCount ?? 0) <= 0 { return false }
            return true
        }
    }

    @State private var query: String = ""
    @State private var sort: SortOrder = .recent
    @State private var filter = Filter()
    @State private var sessions: [HermesSessionSummary] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    /// Server-reported total session count from the unfiltered browse path,
    /// shown in the header. Nil while searching (search has no total) or when an
    /// older server omits it.
    @State private var total: Int?

    // Manage-action state (one set, retargeted per acted-on session).
    @State private var renameTarget: HermesSessionSummary?
    @State private var renameText: String = ""
    @State private var deleteTarget: HermesSessionSummary?
    @State private var isExporting = false
    @State private var exportDocument: TranscriptDocument?
    @State private var exportFilename = "session.jsonl"

    var body: some View {
        Group {
            if let client {
                content(client: client)
            } else {
                DashboardNotReadyView(systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .navigationTitle("Sessions")
    }

    /// True when a search query is in effect. The search path returns lean
    /// summaries (no source/model/lastActive), so filters and the filtered count
    /// apply to the browse list only.
    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The fetched rows narrowed by the active filters. Applies while searching
    /// too: search hits are enriched with browse metadata in `reload`, and rows
    /// outside that window stay lean — their nil fields fail any set filter, so
    /// search + filter compose correctly.
    private var filteredSessions: [HermesSessionSummary] {
        sessions.filter(filter.matches)
    }

    /// Distinct `source` values across the fetched rows, for the Filter menu.
    private var sourceOptions: [String] {
        Set(sessions.compactMap { $0.source }.filter { !$0.isEmpty }).sorted()
    }

    /// Distinct `model` values across the fetched rows, for the Filter menu.
    private var modelOptions: [String] {
        Set(sessions.compactMap { $0.model }.filter { !$0.isEmpty }).sorted()
    }

    /// Header count copy: the filtered count whenever a filter narrows the rows
    /// or a search is active (both operate on the fetched window), else the
    /// server total for the plain browse list. Nil before a total lands.
    private var headerCountText: LocalizedStringKey? {
        if isSearching || filter.isActive {
            return "^[\(filteredSessions.count) session](inflect: true)"
        }
        if let total {
            return "^[\(total) session](inflect: true)"
        }
        return nil
    }

    @ViewBuilder
    private func content(client: DashboardClient) -> some View {
        Group {
            if filteredSessions.isEmpty && !isLoading {
                ContentUnavailableView(
                    (query.isEmpty && !filter.isActive) ? "No Sessions" : "No matches",
                    systemImage: "clock.arrow.circlepath"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredSessions) { summary in
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
                        tuiDisabled: store.isOpenInline(summary.id),
                        // Rename is CLI-only (no dashboard route), so hide it
                        // where the admin runner is absent (iOS). Also hidden
                        // while searching: the lean search summaries carry a
                        // message snippet as `title`, not the real title, so
                        // seeding the rename field from it would let a save
                        // rewrite the session name to an excerpt.
                        onRename: (store.supportsRename && !isSearching) ? {
                            renameText = summary.title
                            renameTarget = summary
                        } : nil,
                        onExport: { exportTranscript(for: summary) },
                        onDelete: { deleteTarget = summary }
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
                if let headerCountText {
                    Text(headerCountText)
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
            ToolbarItem(placement: .primaryAction) {
                filterMenu
            }
        }
        .sheet(item: $renameTarget) { target in
            renameSheet(for: target)
        }
        .confirmationDialog(
            "Delete this session?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { target in
            Button("Delete", role: .destructive) {
                Task { await store.deleteSession(target.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text("“\(sessionLabel(target))” and its transcript will be permanently deleted.")
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: TranscriptDocument.contentType,
            defaultFilename: exportFilename
        ) { _ in
            exportDocument = nil
        }
        .task(id: TaskKey(query: query, sort: sort, refresh: store.browserRefreshToken)) {
            await reload(client: client)
        }
    }

    /// The Filter menu in the toolbar. Stays usable while searching — search
    /// hits are enriched with browse metadata so the same fields filters key on
    /// are present. Badged when any filter is non-default.
    private var filterMenu: some View {
        Menu {
            Picker("Source", selection: $filter.source) {
                Text("Any").tag(String?.none)
                ForEach(sourceOptions, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Picker("Model", selection: $filter.model) {
                Text("Any").tag(String?.none)
                ForEach(modelOptions, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Picker("Last activity", selection: $filter.dateRange) {
                ForEach(DateRange.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Active only", isOn: $filter.activeOnly)
            Divider()
            Picker("Messages", selection: $filter.messageFloor) {
                ForEach(MessageFloor.allCases) { Text($0.label).tag($0) }
            }
            Picker("Tokens", selection: $filter.tokenFloor) {
                ForEach(TokenFloor.allCases) { Text($0.label).tag($0) }
            }
            Picker("Cost", selection: $filter.costFloor) {
                ForEach(CostFloor.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Used tools", isOn: $filter.hasToolCalls)
            Divider()
            Button("Clear filters") { filter = Filter() }
                .disabled(!filter.isActive)
        } label: {
            Label(
                "Filter",
                systemImage: filter.isActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .help("Filter sessions by source, model, activity, size, cost, or tool use")
        .accessibilityLabel("Filter sessions")
    }

    /// Fetches the transcript and arms the file exporter for `summary`. Bails
    /// (leaving the exporter closed) when the fetch fails — `store` surfaces the
    /// error.
    private func exportTranscript(for summary: HermesSessionSummary) {
        Task {
            guard let text = await store.transcriptJSONL(for: summary.id) else {
                return
            }
            exportDocument = TranscriptDocument(text: text)
            exportFilename = "session-\(SessionIdFormatter.short(summary.id)).jsonl"
            isExporting = true
        }
    }

    /// Display name for confirmation copy — the title, or a short id when untitled.
    private func sessionLabel(_ summary: HermesSessionSummary) -> String {
        summary.title.isEmpty ? SessionIdFormatter.short(summary.id) : summary.title
    }

    private func renameSheet(for target: HermesSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename session").font(.headline)
            TextField("Title", text: $renameText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { renameTarget = nil }
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
            // The browse list is the metadata universe. `minMessages: 1` asks
            // Hermes to exclude empty (zero-message) sessions — e.g.
            // gateway/Telegram rows that have nothing to display and would
            // otherwise open a blank transcript. The filter applies to both the
            // list and `total`, so the header count stays consistent. Older
            // Hermes ignores it (no gate). It's also the join source that lets
            // search hits carry source/model/counts/tokens/cost, so the Filter
            // menu works while searching.
            let browse = try await client.listSessions(limit: 200, minMessages: 1)
            let browseRows = browse.sessions.map(HermesSessionSummary.init)
            if trimmed.isEmpty {
                results = browseRows
                total = browse.total
            } else {
                total = nil
                let byId = Dictionary(browseRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let response = try await client.searchSessions(query: trimmed, limit: 200)
                // `/api/sessions/search` returns one hit per matching message, so
                // a session matching in several messages appears multiple times.
                // Keep the first hit per session to give `List` stable, unique IDs.
                var seen = Set<String>()
                results = response.results.compactMap { hit in
                    guard seen.insert(hit.sessionId).inserted else { return nil }
                    let snippet = hit.displaySnippet ?? ""
                    // Enrich recent hits with the browse row (real title +
                    // filterable fields), surfacing the search snippet as the
                    // row preview. Hits outside the top-200 browse window stay
                    // lean (snippet-as-title), preserving search reach — they
                    // just can't satisfy field/threshold filters.
                    if var enriched = byId[hit.sessionId] {
                        if !snippet.isEmpty { enriched.preview = snippet }
                        return enriched
                    }
                    return HermesSessionSummary(
                        id: hit.sessionId,
                        title: snippet,
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
    /// Manage actions, mirroring `open`/`openTUI`. `onRename` is nil where rename
    /// isn't supported (iOS, no CLI admin runner), which hides its button.
    var onRename: (() -> Void)?
    var onExport: () -> Void = {}
    var onDelete: () -> Void = {}

    @State private var isHovering = false

    var body: some View {
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
                // Reserve room for the top-trailing action overlay so a long
                // title never slides under the hover icons. Only the title row
                // is inset; the preview and metadata rows still span full width
                // so the indicators stay flush against the row's trailing edge.
                .padding(.trailing, actionClusterWidth)
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
        // Action icons float on top of the top-trailing corner instead of as
        // siblings in flow, so they reserve no horizontal space in the metadata
        // row — the indicators reach the true trailing edge and align identically
        // across rows regardless of which buttons are present.
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                if let openTUI {
                    rowButton(
                        systemImage: "terminal",
                        help: tuiDisabled
                            ? "Already open inline — close it to open as a terminal session"
                            : "Open as a terminal (TUI) session",
                        accessibility: "Open as TUI",
                        action: openTUI
                    )
                    .disabled(tuiDisabled)
                }
                if let onRename {
                    rowButton(
                        systemImage: "pencil",
                        help: "Rename this session",
                        accessibility: "Rename session",
                        action: onRename
                    )
                }
                rowButton(
                    systemImage: "square.and.arrow.up",
                    help: "Export this session's transcript as JSONL",
                    accessibility: "Export transcript",
                    action: onExport
                )
                rowButton(
                    systemImage: "trash",
                    help: "Delete this session",
                    accessibility: "Delete session",
                    role: .destructive,
                    action: onDelete
                )
            }
        }
        #if os(macOS)
        .onHover { isHovering = $0 }
        #endif
    }

    /// Approximate width of the top-trailing action overlay, used to inset the
    /// title row so text never collides with the hover-revealed icons. Tracks the
    /// buttons actually shown (TUI and rename are conditional) so short-cluster
    /// rows don't waste title width.
    private var actionClusterWidth: CGFloat {
        let buttonCount = 2 + (openTUI != nil ? 1 : 0) + (onRename != nil ? 1 : 0)
        let buttonWidth: CGFloat = 20
        let spacing: CGFloat = 8
        return CGFloat(buttonCount) * buttonWidth + CGFloat(buttonCount - 1) * spacing
    }

    /// A trailing-edge row action button. Always visible on iOS; hover-revealed
    /// on macOS so the row stays clean until pointed at.
    @ViewBuilder
    private func rowButton(
        systemImage: String,
        help: String,
        accessibility: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(accessibility)
        #if os(macOS)
        .opacity(isHovering ? 1 : 0)
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

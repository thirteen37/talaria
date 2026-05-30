import HermesKit
import SwiftUI

@MainActor
@Observable
final class LogsHarness {
    struct Entry: Identifiable, Equatable {
        let id: Int
        let text: String
    }

    var entries: [Entry] = []
    var paused: Bool = false
    var lastError: String?
    /// Server-side level filter applied via `/api/logs?level=`. Empty string
    /// means "all levels" — the dashboard treats absent / blank as no filter.
    var levelFilter: String = ""
    /// Draft component filter bound to the text field. Free text, so it's
    /// only applied to the poll on submit (see `appliedComponentFilter`) —
    /// applying mid-type would let a background poll fetch a partially-typed
    /// filter's tail and corrupt the diff against the last snapshot.
    var componentFilter: String = ""
    /// Draft substring search bound to the text field; applied on submit.
    var searchFilter: String = ""
    /// Committed filters the poll actually sends. Updated from the drafts by
    /// `applyTextFilters()` on submit. The Level picker commits immediately
    /// instead because it's a discrete menu, not free text.
    private var appliedComponentFilter: String = ""
    private var appliedSearchFilter: String = ""
    /// Active log file name, defaults to whatever the dashboard returns
    /// (typically `agent`). Surfaced read-only because Hermes' log layout
    /// isn't user-configurable today.
    var file: String = ""

    /// How many tail lines to request per poll. The dashboard returns the
    /// full tail buffer each time so we deduplicate against `nextID` rather
    /// than asking the server for "lines since X".
    let tailLines: Int

    private var nextID: Int = 0
    private var lastSnapshotLines: [String] = []
    private var task: Task<Void, Never>?
    /// Single-flight epoch. The background loop and `refreshNow()` (Refresh
    /// button, Level picker, filter submits) are independent pollers; without
    /// this, two polls overlapping across the `getLogs` round-trip can both
    /// diff against the same snapshot and double-append, and a poll resolving
    /// after a `clear()` can re-append lines fetched under the old filter.
    /// Each poll bumps this at start and discards its result if a newer poll
    /// (or a `clear()`) bumped it again — latest wins.
    private var pollGeneration: Int = 0
    private let client: DashboardClient
    private let pollInterval: TimeInterval

    init(client: DashboardClient, tailLines: Int = 500, pollInterval: TimeInterval = 2.0) {
        self.client = client
        self.tailLines = tailLines
        self.pollInterval = pollInterval
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.poll()
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func clear() {
        entries.removeAll()
        lastSnapshotLines.removeAll()
        // Invalidate any in-flight poll so its (now stale, possibly
        // old-filter) result doesn't repopulate the just-cleared buffer.
        pollGeneration += 1
    }

    /// Promotes the draft component/search text to the committed filters the
    /// poll sends. Call on submit, paired with `clear()` + a refresh.
    func applyTextFilters() {
        appliedComponentFilter = componentFilter
        appliedSearchFilter = searchFilter
    }

    /// The committed search term the visible lines were actually fetched with
    /// (not the uncommitted draft). Used to highlight matches in the rendered
    /// lines so the overlay tracks what the server filtered on.
    var activeSearchFilter: String { appliedSearchFilter }

    func refreshNow() async {
        await poll()
    }

    private func poll() async {
        if paused { return }
        pollGeneration += 1
        let generation = pollGeneration
        do {
            let response = try await client.getLogs(
                file: nil,
                lines: tailLines,
                level: levelFilter.isEmpty ? nil : levelFilter,
                component: appliedComponentFilter.isEmpty ? nil : appliedComponentFilter,
                search: appliedSearchFilter.isEmpty ? nil : appliedSearchFilter
            )
            // A newer poll (or a clear()) superseded us while awaiting — drop
            // this result rather than diff/append against a snapshot that's
            // moved on, which is what produces duplicate / stale-filter rows.
            guard generation == pollGeneration else { return }
            file = response.file
            // The dashboard returns the most-recent tail on every poll. Diff
            // against the last snapshot — anything that wasn't there last
            // time is "new" and gets appended. This handles both append-only
            // (steady state) and log-rotated (full reset) cases without
            // round-trips for cursor state.
            let newLines = TailDiff.newSuffix(of: response.lines, after: lastSnapshotLines)
            for raw in newLines {
                entries.append(Entry(id: nextID, text: raw))
                nextID += 1
            }
            if entries.count > 5000 {
                entries.removeFirst(entries.count - 5000)
            }
            lastSnapshotLines = response.lines
            lastError = nil
        } catch {
            // Same single-flight guard: don't let a superseded poll's error
            // overwrite the latest poll's state.
            guard generation == pollGeneration else { return }
            lastError = error.localizedDescription
        }
    }

}

struct LogsView: View {
    let client: DashboardClient?
    let hermesVersion: HermesVersion?

    @State private var harness: LogsHarness?
    @State private var autoScroll: Bool = true
    @State private var highlight: Bool = true

    init(client: DashboardClient?, hermesVersion: HermesVersion? = nil) {
        self.client = client
        self.hermesVersion = hermesVersion
    }

    var body: some View {
        Group {
            if client == nil {
                ContentUnavailableView(
                    "Dashboard not ready",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Waiting for the Hermes dashboard to come online.")
                )
            } else if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Logs")
        // Keyed on client availability so the harness is built when the
        // dashboard finishes booting and `client` flips non-nil, not only on
        // first appear (a bare `.task` on the Group never re-runs for that flip).
        .task(id: client != nil) {
            guard let client else { harness = nil; return }
            // Re-appearing after `.onDisappear` left a stopped harness in place:
            // restart its poll loop (idempotent — `start()` guards on `task ==
            // nil`) instead of returning early and leaving tailing dead.
            if let harness { harness.start(); return }
            let h = LogsHarness(client: client)
            harness = h
            h.start()
        }
        .onDisappear {
            harness?.stop()
        }
    }

    @ViewBuilder
    private func content(harness: LogsHarness) -> some View {
        VStack(spacing: 0) {
            filterBar(harness: harness)
            Divider()
            logList(harness: harness)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem {
                Button {
                    let text = harness.entries.map(\.text).joined()
                    copyToPasteboard(text)
                } label: {
                    Label("Copy visible", systemImage: "doc.on.doc")
                }
                .help("Copy the visible log lines")
            }
            ToolbarItem {
                Button {
                    harness.clear()
                    Task { await harness.refreshNow() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Clear and refresh the logs")
            }
        }
        .manageBanner(
            harness.lastError ?? capabilityBanner(
                .requiresDashboard,
                feature: "Logs via Hermes dashboard",
                version: hermesVersion
            ),
            severity: harness.lastError != nil ? .error : .warning
        )
    }

    @ViewBuilder
    private func filterBar(harness: LogsHarness) -> some View {
        HStack(spacing: 12) {
            Picker("Level", selection: Binding(
                get: { harness.levelFilter },
                set: { newValue in
                    harness.levelFilter = newValue
                    harness.clear()
                    Task { await harness.refreshNow() }
                }
            )) {
                Text("All").tag("")
                Text("Debug").tag("DEBUG")
                Text("Info").tag("INFO")
                Text("Warn").tag("WARNING")
                Text("Error").tag("ERROR")
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 160)

            TextField("Component", text: Binding(
                get: { harness.componentFilter },
                set: { harness.componentFilter = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 180)
            .onSubmit {
                harness.applyTextFilters()
                harness.clear()
                Task { await harness.refreshNow() }
            }

            TextField("Search", text: Binding(
                get: { harness.searchFilter },
                set: { harness.searchFilter = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 200)
            .onSubmit {
                harness.applyTextFilters()
                harness.clear()
                Task { await harness.refreshNow() }
            }

            Toggle("Pause", isOn: Binding(
                get: { harness.paused },
                set: { harness.paused = $0 }
            ))
            .toggleStyle(.switch)

            Toggle("Follow", isOn: $autoScroll)
                .toggleStyle(.switch)

            Toggle("Highlight", isOn: $highlight)
                .toggleStyle(.switch)

            Spacer()
            Text("\(harness.entries.count) lines")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func logList(harness: LogsHarness) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(harness.entries) { entry in
                        Text(highlighted(entry.text, search: harness.activeSearchFilter, enabled: highlight))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .onChange(of: harness.entries.last?.id) { _, newValue in
                guard autoScroll, let newValue else { return }
                withAnimation(.linear(duration: 0.05)) {
                    proxy.scrollTo(newValue, anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Renders one tail line as a single `AttributedString` (mirroring
    /// `DoctorView.colorizedBody`) so contiguous selection and "Copy visible"
    /// stay faithful — `LogSyntax.segments` guarantees the pieces concatenate
    /// back to the original line. With `enabled` off it falls straight back to
    /// plain monospaced text.
    private func highlighted(_ text: String, search: String, enabled: Bool) -> AttributedString {
        let line = text.trimmingCharacters(in: .newlines)
        guard enabled else { return AttributedString(line) }
        var result = AttributedString()
        for seg in LogSyntax.segments(of: line) {
            var piece = AttributedString(seg.text)
            if let c = color(for: seg.token) { piece.foregroundColor = c }
            result += piece
        }
        if !search.isEmpty { applySearchHighlight(&result, term: search) }
        return result
    }

    private func color(for token: LogSyntax.Token) -> Color? {
        switch token {
        case .timestamp:               return .secondary
        case .level(.debug):           return .secondary
        case .level(.info):            return .green
        case .level(.warning):         return .orange
        case .level(.error), .level(.critical): return .red
        case .logger:                  return .teal
        case .traceFile:               return .secondary
        case .traceException:          return .red
        case .traceCaret:              return .pink
        case .message, .separator, .plain: return nil   // default foreground
        }
    }

    /// Case-insensitive background overlay for every occurrence of the search
    /// term, applied on top of the foreground syntax colors.
    private func applySearchHighlight(_ s: inout AttributedString, term: String) {
        var searchStart = s.startIndex
        while let r = s[searchStart...].range(of: term, options: .caseInsensitive) {
            s[r].backgroundColor = .yellow.opacity(0.4)
            searchStart = r.upperBound
        }
    }

    private func copyToPasteboard(_ text: String) {
        Pasteboard.copy(text)
    }
}

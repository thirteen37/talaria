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
    /// Server-side component filter, sent as `component=`.
    var componentFilter: String = ""
    /// Server-side substring search, sent as `search=`.
    var searchFilter: String = ""
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
    }

    func refreshNow() async {
        await poll()
    }

    private func poll() async {
        if paused { return }
        do {
            let response = try await client.getLogs(
                file: nil,
                lines: tailLines,
                level: levelFilter.isEmpty ? nil : levelFilter,
                component: componentFilter.isEmpty ? nil : componentFilter,
                search: searchFilter.isEmpty ? nil : searchFilter
            )
            file = response.file
            // The dashboard returns the most-recent tail on every poll. Diff
            // against the last snapshot — anything that wasn't there last
            // time is "new" and gets appended. This handles both append-only
            // (steady state) and log-rotated (full reset) cases without
            // round-trips for cursor state.
            let newLines = Self.suffix(of: response.lines, after: lastSnapshotLines)
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
            lastError = error.localizedDescription
        }
    }

    /// Returns the lines from `current` that weren't already in `previous`,
    /// accounting for the dashboard returning a fixed-size tail window that
    /// slides as new lines land. Algorithm: find the largest `offset` such
    /// that `previous.dropFirst(offset)` equals `current.prefix(of the same
    /// length)`; new lines are everything in `current` after that. Falls
    /// back to "treat as full reset" when no overlap is found (log rotation,
    /// filter change, fresh start).
    static func suffix(of current: [String], after previous: [String]) -> [String] {
        if previous.isEmpty { return current }
        if current.isEmpty { return [] }
        for offset in 0..<previous.count {
            let trailingLen = previous.count - offset
            if current.count < trailingLen { continue }
            let previousTail = previous[offset...]
            let currentHead = current[..<trailingLen]
            if Array(previousTail) == Array(currentHead) {
                return Array(current[trailingLen...])
            }
        }
        return current
    }
}

struct LogsView: View {
    let client: DashboardClient?
    let hermesVersion: HermesVersion?

    @State private var harness: LogsHarness?
    @State private var autoScroll: Bool = true

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
        .task {
            guard let client else { harness = nil; return }
            if harness != nil { return }
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
            }
            ToolbarItem {
                Button {
                    harness.clear()
                    Task { await harness.refreshNow() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
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
                        Text(entry.text.trimmingCharacters(in: .newlines))
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

    private func copyToPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

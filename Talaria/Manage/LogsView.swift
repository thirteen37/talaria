import HermesKit
import SwiftUI

@MainActor
@Observable
final class LogsHarness {
    struct Entry: Identifiable, Equatable {
        let id: Int
        let line: LogLine
    }

    var entries: [Entry] = []
    var paused: Bool = false
    var lastError: String?
    var levelFilter: LogLevel?  // nil = All
    var componentFilter: String = ""

    /// Max lines retained in the ring buffer. Older lines are dropped from the
    /// front when this is exceeded so the UI doesn't OOM on noisy logs.
    let ringCapacity: Int

    private var nextID: Int = 0
    private var task: Task<Void, Never>?
    private let tailing: HermesLogTailing

    init(tailing: HermesLogTailing, ringCapacity: Int = 5000) {
        self.tailing = tailing
        self.ringCapacity = ringCapacity
    }

    func start() {
        guard task == nil else { return }
        let stream = tailing.tail(component: nil)
        task = Task { [weak self] in
            do {
                for try await line in stream {
                    guard let self else { return }
                    if Task.isCancelled { return }
                    if self.paused { continue }
                    self.append(line)
                }
            } catch is CancellationError {
                // stop() was called (onDisappear, view tear-down) — not an
                // error the user needs to see on next appear.
                return
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func clear() {
        entries.removeAll()
    }

    func filtered() -> [Entry] {
        let component = componentFilter.trimmingCharacters(in: .whitespaces)
        let level = levelFilter
        guard !component.isEmpty || level != nil else { return entries }
        return entries.filter { entry in
            if let level, entry.line.level != level { return false }
            if !component.isEmpty,
               !entry.line.component.localizedCaseInsensitiveContains(component) {
                return false
            }
            return true
        }
    }

    private func append(_ line: LogLine) {
        let entry = Entry(id: nextID, line: line)
        nextID += 1
        entries.append(entry)
        if entries.count > ringCapacity {
            entries.removeFirst(entries.count - ringCapacity)
        }
    }
}

struct LogsView: View {
    let runner: HermesAdminRunning?
    let profile: ServerProfile

    @State private var harness: LogsHarness?
    @State private var autoScroll: Bool = true

    var body: some View {
        Group {
            if let harness {
                content(harness: harness)
            } else if profile.hermesHome == nil {
                ContentUnavailableView(
                    "Logs path unknown",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Set HERMES_HOME on the profile to tail logs.")
                )
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Logs")
        .task {
            if harness == nil, let tailing = makeTailing() {
                harness = LogsHarness(tailing: tailing)
            }
            // start() is idempotent — calling it on every appear restarts the
            // tailer after a backgrounded window / sheet teardown closed it
            // via onDisappear. Without this the view shows the buffered lines
            // forever without picking up new ones.
            harness?.start()
        }
        .onDisappear {
            harness?.stop()
        }
    }

    private func makeTailing() -> HermesLogTailing? {
        guard let hermesHome = profile.hermesHome, !hermesHome.isEmpty else { return nil }
        #if os(macOS)
        switch profile.kind {
        case .local:
            return LocalLogTailing(hermesHome: hermesHome)
        case .ssh:
            return RemoteLogTailing(profile: profile, hermesHome: hermesHome)
        }
        #else
        return nil
        #endif
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
                    let text = harness.filtered().map(\.line.raw).joined(separator: "\n")
                    copyToPasteboard(text)
                } label: {
                    Label("Copy visible", systemImage: "doc.on.doc")
                }
            }
            ToolbarItem {
                Button {
                    harness.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            }
        }
        .manageBanner(harness.lastError)
    }

    @ViewBuilder
    private func filterBar(harness: LogsHarness) -> some View {
        HStack(spacing: 12) {
            Picker("Level", selection: Binding(
                get: { harness.levelFilter },
                set: { harness.levelFilter = $0 }
            )) {
                Text("All").tag(LogLevel?.none)
                Text("Debug").tag(LogLevel?.some(.debug))
                Text("Info").tag(LogLevel?.some(.info))
                Text("Warn").tag(LogLevel?.some(.warn))
                Text("Error").tag(LogLevel?.some(.error))
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 160)

            TextField("Component", text: Binding(
                get: { harness.componentFilter },
                set: { harness.componentFilter = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 220)

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
        let visible = harness.filtered()
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(visible) { entry in
                        LogLineRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .onChange(of: visible.last?.id) { _, newValue in
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

private struct LogLineRow: View {
    let entry: LogsHarness.Entry

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if let ts = entry.line.timestamp {
                Text(ts.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)))
                    .foregroundStyle(.secondary)
                    .font(.system(.caption, design: .monospaced))
            }
            Text(levelLabel)
                .foregroundStyle(levelColor)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 50, alignment: .leading)
            if !entry.line.component.isEmpty {
                Text(entry.line.component)
                    .foregroundStyle(.purple)
                    .font(.system(.caption, design: .monospaced))
            }
            Text(entry.line.message)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var levelLabel: String {
        switch entry.line.level {
        case .debug: return "DBG"
        case .info: return "INF"
        case .warn: return "WRN"
        case .error: return "ERR"
        case .unknown: return ""
        }
    }

    private var levelColor: Color {
        switch entry.line.level {
        case .debug: return .gray
        case .info: return .blue
        case .warn: return .orange
        case .error: return .red
        case .unknown: return .secondary
        }
    }
}

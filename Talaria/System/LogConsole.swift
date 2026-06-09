import Foundation
import OSLog
import SwiftUI

/// Reads this process's own `os.Logger` entries (subsystem prefix
/// `com.talaria`) back out via `OSLogStore` so they can be shown on-device.
/// Essential for debugging SSH failures on iPhone, where there's no attached
/// Xcode console.
enum LogConsole {
    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let category: String
        let level: String
        let message: String
    }

    /// Reads recent `com.talaria.*` log entries. Runs synchronously and can be
    /// slow on a chatty process — call from a background task.
    static func recentEntries(sinceMinutes: Int = 30) -> [Entry] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let start = store.position(date: Date().addingTimeInterval(TimeInterval(-60 * sinceMinutes)))
            var result: [Entry] = []
            for case let log as OSLogEntryLog in try store.getEntries(at: start)
            where log.subsystem.hasPrefix("com.talaria") {
                result.append(Entry(
                    date: log.date,
                    category: log.category,
                    level: levelString(log.level),
                    message: log.composedMessage
                ))
            }
            return result
        } catch {
            return [Entry(date: Date(), category: "logconsole", level: "error",
                          message: "Couldn't read logs: \(error.localizedDescription)")]
        }
    }

    private static func levelString(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        case .undefined: return "—"
        @unknown default: return "?"
        }
    }
}

/// On-screen log viewer. Pull-to-refresh-free; an explicit Refresh button
/// reloads, and Copy puts the whole transcript on the pasteboard so it can be
/// shared from the device.
///
/// `onDismiss` is nil when the view is embedded (e.g. the Browse → System
/// "App Logs" tab); the toolbar then omits its Done button. Pass a closure only
/// when presenting it modally.
struct LogConsoleView: View {
    var onDismiss: (() -> Void)? = nil

    @State private var entries: [LogConsole.Entry] = []
    @State private var isLoading = false

    var body: some View {
        // Modal presentation owns its navigation chrome, so wrap in a
        // NavigationStack. When embedded (e.g. the Browse → System "App Logs"
        // tab) the host already provides one — wrapping again would nest a
        // second navigation bar inside it, so render bare and let the title +
        // Copy/Refresh toolbar attach to the host's bar like the sibling tabs.
        if onDismiss != nil {
            NavigationStack { content }
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    isLoading ? "Loading…" : "No logs yet",
                    systemImage: "doc.text.magnifyingglass"
                )
            } else {
                List(entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.message)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Text("\(entry.category) · \(entry.level) · \(entry.date.formatted(date: .omitted, time: .standard))")
                            .font(.caption2)
                            .foregroundStyle(entry.level == "error" || entry.level == "fault" ? .red : .secondary)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Logs")
        .inlineNavigationTitle()
        .logConsoleToolbar(
            onCopy: { copyAll() },
            onRefresh: { Task { await reload() } },
            onDismiss: onDismiss
        )
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        let loaded = await Task.detached(priority: .userInitiated) {
            LogConsole.recentEntries()
        }.value
        entries = loaded
        isLoading = false
    }

    private func copyAll() {
        let text = entries
            .map { "\($0.date.formatted(date: .omitted, time: .standard)) [\($0.category)/\($0.level)] \($0.message)" }
            .joined(separator: "\n")
        Pasteboard.copy(text)
    }
}

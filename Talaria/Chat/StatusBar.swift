import SwiftUI

struct StatusBar: View {
    var statusText: String?
    var hasError: Bool
    var isSending: Bool
    var turnStartDate: Date?
    var gitBranch: String?
    var contextUsed: Int?
    var contextSize: Int?
    /// "ACP" or "WS" — which live-chat transport this session uses. Hidden when
    /// nil (read-only sessions, or before the backend has booted).
    var backendBadge: String?

    @State private var now = Date()
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 12) {
            Label(statusText ?? "Idle", systemImage: statusImage)
                .foregroundStyle(hasError ? .red : .secondary)

            if let elapsedText {
                Text(elapsedText)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let contextText {
                Label(contextText, systemImage: "gauge.with.dots.needle.33percent")
                    .foregroundStyle(.secondary)
            }

            if let gitBranch {
                Label(gitBranch, systemImage: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
            }

            if let backendBadge {
                Text(backendBadge)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
                    .help(backendBadge == "WS"
                        ? "Live chat is running over the dashboard /api/ws gateway"
                        : "Live chat is running over the ACP subprocess")
                    .accessibilityLabel("Chat backend \(backendBadge)")
            }
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear {
            updateTimer(isActive: isSending)
        }
        .onChange(of: isSending) { _, isSending in
            updateTimer(isActive: isSending)
        }
        .onDisappear {
            stopTimer()
        }
    }

    private var statusImage: String {
        if hasError {
            return "exclamationmark.triangle"
        }
        return isSending ? "bolt.fill" : "checkmark.circle"
    }

    private var elapsedText: String? {
        guard let turnStartDate, isSending else {
            return nil
        }
        let seconds = max(0, Int(now.timeIntervalSince(turnStartDate)))
        return "\(seconds)s"
    }

    private var contextText: String? {
        guard let contextUsed, let contextSize, contextSize > 0 else {
            return nil
        }
        let pct = Int((Double(contextUsed) / Double(contextSize) * 100).rounded())
        return "\(formatTokens(contextUsed)) / \(formatTokens(contextSize)) (\(pct)%)"
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
    }

    private func updateTimer(isActive: Bool) {
        now = Date()
        if isActive {
            startTimer()
        } else {
            stopTimer()
        }
    }

    private func startTimer() {
        guard timer == nil else {
            return
        }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                now = Date()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

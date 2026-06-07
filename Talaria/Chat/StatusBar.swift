import SwiftUI

struct StatusBar: View {
    var statusText: String?
    var hasError: Bool
    var isSending: Bool
    var turnStartDate: Date?
    var model: String?
    var gitBranch: String?
    var contextUsed: Int?
    var contextSize: Int?

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

            if let model, !model.isEmpty {
                EntityLink(ref: .modelMain, style: .subtle) {
                    Label(model, systemImage: "cpu")
                }
                .foregroundStyle(.secondary)
            }

            if let contextText {
                Label(contextText, systemImage: "gauge.with.dots.needle.33percent")
                    .foregroundStyle(.secondary)
            }

            if let gitBranch {
                Label(gitBranch, systemImage: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
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

import SwiftUI

struct StatusBar: View {
    var statusText: String?
    var hasError: Bool
    var isSending: Bool
    var turnStartDate: Date?
    var gitBranch: String?

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

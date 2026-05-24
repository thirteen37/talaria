import HermesKit
import SwiftUI

@MainActor
@Observable
final class UpdatesHarness {
    struct LogEntry: Identifiable, Equatable {
        let id: Int
        let text: String
    }

    var status: UpdateStatus?
    var isChecking: Bool = false
    var isApplying: Bool = false
    var applyLog: [LogEntry] = []
    var applyExitCode: Int32?
    var lastError: String?

    let runner: HermesAdminRunning?

    private var nextLogID: Int = 0
    private var applyTask: Task<Void, Never>?

    init(runner: HermesAdminRunning?) {
        self.runner = runner
    }

    private func appendLog(_ text: String) {
        applyLog.append(LogEntry(id: nextLogID, text: text))
        nextLogID += 1
        if applyLog.count > 5000 {
            applyLog.removeFirst(applyLog.count - 5000)
        }
    }

    func check() async {
        guard let runner else { return }
        isChecking = true
        defer { isChecking = false }
        lastError = nil
        do {
            status = try await HermesUpdates.check(runner: runner)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func apply() {
        guard let runner, !isApplying else { return }
        isApplying = true
        applyLog.removeAll()
        applyExitCode = nil
        lastError = nil
        let stream = HermesUpdates.apply(runner: runner)
        applyTask = Task { [weak self] in
            defer { Task { @MainActor in self?.isApplying = false } }
            do {
                for try await event in stream {
                    guard let self else { return }
                    switch event {
                    case .stdoutLine(let line), .stderrLine(let line):
                        self.appendLog(line)
                    case .exit(let code):
                        self.applyExitCode = code
                    }
                }
            } catch is CancellationError {
                // User tapped Cancel — normal exit path, no banner.
                return
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    func cancelApply() {
        applyTask?.cancel()
        applyTask = nil
    }
}

struct UpdatesView: View {
    let runner: HermesAdminRunning?

    @State private var harness: UpdatesHarness?

    var body: some View {
        Group {
            if runner == nil {
                ContentUnavailableView(
                    "Admin runner unavailable",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("Open a profile with a Hermes binary to check for updates.")
                )
            } else if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Updates")
        .task {
            if runner == nil { harness = nil; return }
            if harness != nil { return }
            let h = UpdatesHarness(runner: runner)
            harness = h
            await h.check()
        }
    }

    @ViewBuilder
    private func content(harness: UpdatesHarness) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            statusBanner(harness: harness)
            HStack(spacing: 8) {
                Button {
                    Task { await harness.check() }
                } label: {
                    Label("Check", systemImage: "arrow.clockwise")
                }
                .disabled(harness.isChecking)

                Button {
                    harness.apply()
                } label: {
                    Label("Install update", systemImage: "arrow.down.circle.fill")
                }
                .disabled(
                    harness.isApplying
                    || harness.status?.available != true
                )

                if harness.isApplying {
                    Button("Cancel") { harness.cancelApply() }
                }

                if harness.isChecking || harness.isApplying {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if let code = harness.applyExitCode {
                    Text("Apply exited \(code)")
                        .font(.caption)
                        .foregroundStyle(code == 0 ? .green : .red)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            applyLogView(harness: harness)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .manageBanner(harness.lastError)
    }

    @ViewBuilder
    private func statusBanner(harness: UpdatesHarness) -> some View {
        if let status = harness.status {
            HStack(spacing: 8) {
                Image(systemName: status.available ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(status.available ? Color.accentColor : .green)
                VStack(alignment: .leading, spacing: 2) {
                    if status.available, let latest = status.latest {
                        Text("Update available")
                            .font(.headline)
                        Text("\(formatVersion(status.current)) → \(formatVersion(latest))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Up to date")
                            .font(.headline)
                        Text("Current \(formatVersion(status.current))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background((status.available ? Color.accentColor : Color.green).opacity(0.12))
        }
    }

    @ViewBuilder
    private func applyLogView(harness: UpdatesHarness) -> some View {
        if harness.applyLog.isEmpty {
            ContentUnavailableView("Update log", systemImage: "text.viewfinder", description: Text("Output appears here once an update is applied."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(harness.applyLog) { entry in
                            Text(entry.text)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .onChange(of: harness.applyLog.last?.id) { _, newValue in
                    if let newValue {
                        proxy.scrollTo(newValue, anchor: .bottom)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func formatVersion(_ v: HermesVersion) -> String {
        var s = "\(v.major).\(v.minor).\(v.patch)"
        if let pre = v.prerelease { s += "-\(pre)" }
        return s
    }
}

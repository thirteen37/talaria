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
                var exit: Int32?
                for try await event in stream {
                    guard let self else { return }
                    switch event {
                    case .stdoutLine(let line), .stderrLine(let line):
                        self.appendLog(line)
                    case .exit(let code):
                        self.applyExitCode = code
                        exit = code
                    }
                }
                // Refresh the status banner once the update applies cleanly
                // so the "Install update" button disables itself and the
                // "X commits behind"/version subtitle reflects post-update
                // reality. On non-zero exits the previous status is still
                // accurate, so leave it alone.
                if exit == 0 {
                    await self?.check()
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
    let updates: UpdatesHarness?
    let hermesVersion: HermesVersion?

    init(updates: UpdatesHarness?, hermesVersion: HermesVersion? = nil) {
        self.updates = updates
        self.hermesVersion = hermesVersion
    }

    var body: some View {
        Group {
            if let updates, updates.runner != nil {
                content(harness: updates)
            } else {
                // No shell/admin runner (e.g. a dashboard-only or mock
                // profile): `hermes update --check` is a CLI path, so there's
                // nothing to ask. Surface that rather than a false verdict.
                ContentUnavailableView(
                    "Admin runner unavailable",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("Open a server with a Hermes binary to check for updates.")
                )
            }
        }
        .navigationTitle("Updates")
        // Kick off the first check once the harness is available. `status ==
        // nil` guards against clobbering an in-flight apply when the user
        // navigates back mid-apply — the apply log persists.
        .task(id: updates != nil) {
            guard let updates, updates.runner != nil, updates.status == nil else { return }
            await updates.check()
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
                // Also block while an apply runs: `check()` spawns `hermes
                // update --check` (a git fetch) which would race the in-flight
                // `hermes update` on the same source-install repo and could
                // clobber status/lastError mid-apply.
                .disabled(harness.isChecking || harness.isApplying)

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
        .manageBanner(
            harness.lastError ?? capabilityBanner(
                .updateCheck,
                feature: "`hermes update --check`",
                version: hermesVersion
            ),
            severity: harness.lastError != nil ? .error : .warning
        )
    }

    @ViewBuilder
    private func statusBanner(harness: UpdatesHarness) -> some View {
        if let status = harness.status {
            HStack(spacing: 8) {
                Image(systemName: status.available ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(status.available ? Color.accentColor : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.available ? "Update available" : "Up to date")
                        .font(.headline)
                    if let subtitle = subtitle(for: status) {
                        Text(subtitle)
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

    /// Prefer the semver delta when both versions are known; otherwise
    /// surface the human-readable detail string (e.g. "122 commits behind
    /// origin/main") that the source-install update notice provides.
    private func subtitle(for status: UpdateStatus) -> String? {
        if status.available, let current = status.current, let latest = status.latest {
            return "\(formatVersion(current)) → \(formatVersion(latest))"
        }
        if let current = status.current, !status.available {
            return "Current \(formatVersion(current))"
        }
        return status.detail
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

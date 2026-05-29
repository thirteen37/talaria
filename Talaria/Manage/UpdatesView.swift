import HermesKit
import SwiftUI

@MainActor
@Observable
final class UpdatesHarness {
    struct LogEntry: Identifiable, Equatable {
        let id: Int
        let text: String
    }

    var state: DashboardUpdateState?
    var isLoading: Bool = false
    var isApplying: Bool = false
    var applyLog: [LogEntry] = []
    var applyExitCode: Int32?
    var lastError: String?

    private let service: DashboardUpdatesService
    private var nextLogID: Int = 0
    private var applyTask: Task<Void, Never>?

    init(service: DashboardUpdatesService) {
        self.service = service
    }

    private func appendLines(_ lines: [String]) {
        for line in lines {
            applyLog.append(LogEntry(id: nextLogID, text: line))
            nextLogID += 1
        }
        if applyLog.count > 5000 {
            applyLog.removeFirst(applyLog.count - 5000)
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        lastError = nil
        do {
            state = try await service.currentState()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func apply() {
        guard !isApplying else { return }
        isApplying = true
        applyLog.removeAll()
        applyExitCode = nil
        lastError = nil
        let stream = service.apply()
        applyTask = Task { [weak self] in
            defer { Task { @MainActor in self?.isApplying = false } }
            do {
                for try await event in stream {
                    guard let self else { return }
                    switch event {
                    case .logLines(let lines):
                        self.appendLines(lines)
                    case .finished(let code):
                        self.applyExitCode = code
                    }
                }
                // Re-read the version banner so it reflects the post-update
                // state.
                await self?.refresh()
            } catch is CancellationError {
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
    let client: DashboardClient?
    let hermesVersion: HermesVersion?

    @State private var harness: UpdatesHarness?

    init(client: DashboardClient?, hermesVersion: HermesVersion? = nil) {
        self.client = client
        self.hermesVersion = hermesVersion
    }

    var body: some View {
        Group {
            if client == nil {
                ContentUnavailableView(
                    "Dashboard not ready",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("Waiting for the Hermes dashboard to come online.")
                )
            } else if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Updates")
        // Keyed on client availability so the harness is built when the
        // dashboard finishes booting and `client` flips non-nil, not only on
        // first appear (a bare `.task` on the Group never re-runs for that flip).
        .task(id: client != nil) {
            guard let client else { harness = nil; return }
            if harness != nil { return }
            let h = UpdatesHarness(service: DashboardUpdatesService(client: client))
            harness = h
            await h.refresh()
        }
    }

    @ViewBuilder
    private func content(harness: UpdatesHarness) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            statusBanner(harness: harness)
            HStack(spacing: 8) {
                Button {
                    Task { await harness.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(harness.isLoading || harness.isApplying)

                Button {
                    harness.apply()
                } label: {
                    Label("Update Hermes", systemImage: "arrow.down.circle.fill")
                }
                .disabled(harness.isApplying)

                if harness.isApplying {
                    Button("Cancel") { harness.cancelApply() }
                }

                if harness.isLoading || harness.isApplying {
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
                .requiresDashboard,
                feature: "Hermes dashboard (`pip install hermes-agent[web]`)",
                version: hermesVersion
            ),
            severity: harness.lastError != nil ? .error : .warning
        )
    }

    @ViewBuilder
    private func statusBanner(harness: UpdatesHarness) -> some View {
        if let state = harness.state {
            // Neutral presentation: the dashboard `/api/status` reports the
            // installed version but no "is an update available" flag, so we
            // can't honestly render an up-to-date checkmark. Show an info
            // glyph with just the version; the user decides whether to run
            // "Update Hermes".
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hermes \(state.version)")
                        .font(.headline)
                    if let release = state.releaseDate {
                        Text("Release \(release)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.1))
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
}

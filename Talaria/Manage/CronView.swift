import HermesKit
import SwiftUI

struct CronDraft: Equatable {
    var schedule: String = ""
    var prompt: String = ""
    var name: String = ""
}

@MainActor
@Observable
final class CronHarness {
    var jobs: [DashboardCronJob] = []
    var lastError: String?
    var isLoading: Bool = false
    var selectionID: DashboardCronJob.ID?
    var draft: CronDraft?

    private let client: DashboardClient

    init(client: DashboardClient) {
        self.client = client
    }

    var selectedJob: DashboardCronJob? {
        guard let id = selectionID else { return nil }
        return jobs.first(where: { $0.id == id })
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            jobs = try await client.listCronJobs()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func beginAdd() {
        draft = CronDraft()
        selectionID = nil
    }

    func cancelAdd() { draft = nil }

    func commitAdd(prompt: String, schedule: String, name: String) async {
        do {
            _ = try await client.createCronJob(
                prompt: prompt,
                schedule: schedule,
                name: name.isEmpty ? nil : name
            )
            draft = nil
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Patches a cron job. Pass `schedule == nil` to leave the existing
    /// schedule alone — interval jobs use it because the editor only
    /// supports cron expressions today, and sending the human-readable
    /// "every 60m" display string back would either be rejected by the
    /// dashboard or accepted and then mis-rendered.
    func updateJob(_ job: DashboardCronJob, prompt: String, schedule: String?) async {
        do {
            var updates: [String: String] = ["prompt": prompt]
            if let schedule {
                updates["schedule"] = schedule
            }
            try await client.updateCronJob(id: job.id, updates: updates)
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func delete(_ job: DashboardCronJob) async {
        do {
            try await client.deleteCronJob(id: job.id)
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setEnabled(_ job: DashboardCronJob, enabled: Bool) async {
        do {
            if enabled {
                try await client.resumeCronJob(id: job.id)
            } else {
                try await client.pauseCronJob(id: job.id)
            }
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func runNow(_ job: DashboardCronJob) async {
        do {
            try await client.triggerCronJob(id: job.id)
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

struct CronView: View {
    let client: DashboardClient?
    let hermesVersion: HermesVersion?

    @State private var harness: CronHarness?

    init(client: DashboardClient?, hermesVersion: HermesVersion? = nil) {
        self.client = client
        self.hermesVersion = hermesVersion
    }

    var body: some View {
        Group {
            if client == nil {
                ContentUnavailableView(
                    "Dashboard not ready",
                    systemImage: "calendar.badge.clock",
                    description: Text("Waiting for the Hermes dashboard to come online.")
                )
            } else if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Cron")
        .task {
            guard let client else { harness = nil; return }
            if harness != nil { return }
            let h = CronHarness(client: client)
            harness = h
            await h.refresh()
        }
    }

    @ViewBuilder
    private func content(harness: CronHarness) -> some View {
        HSplitView {
            jobsTable(harness: harness)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            editorPane(harness: harness)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { toolbar(harness: harness) }
        .manageBanner(
            harness.lastError ?? capabilityBanner(
                .requiresDashboard,
                feature: "Cron via Hermes dashboard",
                version: hermesVersion
            ),
            severity: harness.lastError != nil ? .error : .warning
        )
    }

    @ViewBuilder
    private func jobsTable(harness: CronHarness) -> some View {
        Table(harness.jobs, selection: Binding(
            get: { harness.selectionID },
            set: { harness.selectionID = $0 }
        )) {
            TableColumn("Name") { job in
                Text(job.name ?? job.id)
            }
            TableColumn("Schedule") { job in
                Text(scheduleDisplay(job.schedule))
                    .font(.system(.body, design: .monospaced))
            }
            TableColumn("Prompt") { job in
                Text(job.prompt).lineLimit(1).truncationMode(.tail)
            }
            TableColumn("Enabled") { job in
                Toggle("", isOn: Binding(
                    get: { job.enabled },
                    set: { newValue in Task { await harness.setEnabled(job, enabled: newValue) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .width(80)
        }
        .overlay {
            if harness.jobs.isEmpty, !harness.isLoading {
                ContentUnavailableView("No cron jobs", systemImage: "calendar")
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(harness: CronHarness) -> some ToolbarContent {
        ToolbarItemGroup {
            Button { Task { await harness.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(harness.isLoading)
            Button {
                harness.beginAdd()
            } label: {
                Label("Add", systemImage: "plus")
            }
            .disabled(harness.draft != nil)
            Button {
                guard let job = harness.selectedJob else { return }
                Task { await harness.delete(job) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(harness.selectionID == nil)
            Button {
                guard let job = harness.selectedJob else { return }
                Task { await harness.runNow(job) }
            } label: {
                Label("Run Now", systemImage: "play")
            }
            .disabled(harness.selectionID == nil)
        }
    }

    @ViewBuilder
    private func editorPane(harness: CronHarness) -> some View {
        if harness.draft != nil {
            DraftJobEditor(
                draft: Binding(
                    get: { harness.draft ?? CronDraft() },
                    set: { harness.draft = $0 }
                ),
                onSave: { prompt, schedule, name in
                    Task { await harness.commitAdd(prompt: prompt, schedule: schedule, name: name) }
                },
                onCancel: { harness.cancelAdd() }
            )
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if let job = harness.selectedJob {
            JobEditor(job: job) { prompt, schedule in
                Task { await harness.updateJob(job, prompt: prompt, schedule: schedule) }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ContentUnavailableView("Select a job", systemImage: "sidebar.right")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func scheduleDisplay(_ schedule: DashboardCronSchedule) -> String {
        schedule.display ?? schedule.expr ?? (schedule.minutes.map { "every \($0)m" } ?? schedule.kind)
    }
}

private struct DraftJobEditor: View {
    @Binding var draft: CronDraft
    let onSave: (String, String, String) -> Void
    let onCancel: () -> Void

    var body: some View {
        Form {
            Section("New cron job") {
                TextField("Name (optional)", text: $draft.name)
                TextField("Schedule (e.g. */5 * * * *)", text: $draft.schedule)
                    .font(.system(.body, design: .monospaced))
                TextField("Prompt", text: $draft.prompt, axis: .vertical)
                    .lineLimit(3...8)
            }
            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button("Add") {
                    onSave(draft.prompt, draft.schedule, draft.name)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(
                    draft.schedule.trimmingCharacters(in: .whitespaces).isEmpty
                    || draft.prompt.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
        }
    }
}

private struct JobEditor: View {
    let job: DashboardCronJob
    /// Schedule arg is nil when the job's underlying schedule isn't editable
    /// (today: anything that isn't a cron expression — interval jobs in
    /// particular). The harness leaves the schedule untouched in that case.
    let onSave: (String, String?) -> Void

    @State private var prompt: String
    @State private var cronExpression: String

    private var isCronSchedule: Bool { job.schedule.kind == "cron" }

    init(job: DashboardCronJob, onSave: @escaping (String, String?) -> Void) {
        self.job = job
        self.onSave = onSave
        self._prompt = State(initialValue: job.prompt)
        self._cronExpression = State(initialValue: job.schedule.expr ?? "")
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("ID") {
                    Text(job.id).font(.system(.body, design: .monospaced))
                }
                if let name = job.name {
                    LabeledContent("Name") { Text(name) }
                }
                if isCronSchedule {
                    TextField("Schedule", text: $cronExpression)
                        .font(.system(.body, design: .monospaced))
                } else {
                    LabeledContent("Schedule") {
                        Text(job.schedule.display ?? scheduleFallback)
                            .font(.system(.body, design: .monospaced))
                    }
                    Text("Interval schedules can only be edited through `hermes cron` today; the dashboard PUT accepts cron expressions only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Prompt", text: $prompt, axis: .vertical)
                    .lineLimit(3...8)
                if let lastRunAt = job.lastRunAt {
                    LabeledContent("Last Run") { Text(lastRunAt) }
                }
                if let state = job.state {
                    LabeledContent("State") { Text(state) }
                }
            }
            HStack {
                Spacer()
                Button("Save") {
                    onSave(prompt, isCronSchedule ? cronExpression : nil)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(saveDisabled)
            }
        }
        .id(job.id)
    }

    private var saveDisabled: Bool {
        if prompt.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if isCronSchedule, cronExpression.trimmingCharacters(in: .whitespaces).isEmpty {
            return true
        }
        return false
    }

    private var scheduleFallback: String {
        job.schedule.minutes.map { "every \($0)m" } ?? job.schedule.kind
    }
}

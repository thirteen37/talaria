import HermesKit
import SwiftUI

struct CronDraft: Equatable {
    var schedule: String = ""
    var command: String = ""
}

@MainActor
@Observable
final class CronHarness {
    var jobs: [CronJob] = []
    var lastError: String?
    var isLoading: Bool = false
    /// Set to `true` once any call surfaces `commandUnavailable`, so the view
    /// can banner instead of looking permanently broken.
    var cronUnavailable: Bool = false
    var selectionID: CronJob.ID?
    /// Non-nil while the user is composing a new job; the editor pane binds
    /// to this and only calls `hermes cron add` on explicit Save.
    var draft: CronDraft?

    let runner: HermesAdminRunning?

    init(runner: HermesAdminRunning?) {
        self.runner = runner
    }

    func refresh() async {
        guard let runner else { jobs = []; return }
        isLoading = true
        defer { isLoading = false }
        do {
            jobs = try await HermesCron.list(runner: runner)
            cronUnavailable = false
            lastError = nil
        } catch {
            handle(error)
        }
    }

    func beginAdd() {
        draft = CronDraft()
        selectionID = nil
    }

    func cancelAdd() {
        draft = nil
    }

    func commitAdd(schedule: String, command: String) async {
        guard let runner else { return }
        do {
            try await HermesCron.add(runner: runner, schedule: schedule, command: command)
            draft = nil
            await refresh()
        } catch {
            handle(error)
        }
    }

    func update(_ job: CronJob, schedule: String, command: String) async {
        guard let runner else { return }
        do {
            try await HermesCron.update(runner: runner, id: job.id, schedule: schedule, command: command)
            await refresh()
        } catch { handle(error) }
    }

    func delete(_ job: CronJob) async {
        guard let runner else { return }
        do {
            try await HermesCron.delete(runner: runner, id: job.id)
            await refresh()
        } catch { handle(error) }
    }

    func setEnabled(_ job: CronJob, enabled: Bool) async {
        guard let runner else { return }
        do {
            if enabled {
                try await HermesCron.resume(runner: runner, id: job.id)
            } else {
                try await HermesCron.pause(runner: runner, id: job.id)
            }
            await refresh()
        } catch { handle(error) }
    }

    func runNow(_ job: CronJob) async {
        guard let runner else { return }
        do {
            try await HermesCron.runNow(runner: runner, id: job.id)
            await refresh()
        } catch { handle(error) }
    }

    /// Single funnel so `commandUnavailable` consistently flips the banner
    /// regardless of which mutator hit it — a user on an older Hermes who
    /// first tries pause/resume should see the same friendly banner the list
    /// path would surface.
    private func handle(_ error: Error) {
        if let cronError = error as? HermesCronError, case .commandUnavailable = cronError {
            cronUnavailable = true
            lastError = nil
            jobs = []
            return
        }
        lastError = error.localizedDescription
    }
}

struct CronView: View {
    let runner: HermesAdminRunning?

    @State private var harness: CronHarness?

    var body: some View {
        Group {
            if runner == nil {
                ContentUnavailableView(
                    "Admin runner unavailable",
                    systemImage: "calendar.badge.clock",
                    description: Text("Open a profile with a Hermes binary to manage cron jobs.")
                )
            } else if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Cron")
        .task {
            if runner == nil { harness = nil; return }
            if harness != nil { return }
            let h = CronHarness(runner: runner)
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
            harness.cronUnavailable ? "Cron CRUD unavailable in this Hermes version." : harness.lastError,
            severity: harness.cronUnavailable ? .warning : .error
        )
    }

    @ViewBuilder
    private func jobsTable(harness: CronHarness) -> some View {
        Table(harness.jobs, selection: Binding(get: { harness.selectionID }, set: { harness.selectionID = $0 })) {
            TableColumn("ID") { Text($0.id).font(.system(.body, design: .monospaced)) }
            TableColumn("Schedule") { Text($0.schedule).font(.system(.body, design: .monospaced)) }
            TableColumn("Command") { Text($0.command).lineLimit(1).truncationMode(.tail) }
            TableColumn("Enabled") { job in
                Toggle("", isOn: Binding(
                    get: { job.enabled },
                    set: { newValue in Task { await harness.setEnabled(job, enabled: newValue) } }
                ))
                .labelsHidden()
            }
            .width(80)
        }
        .overlay {
            if harness.jobs.isEmpty, !harness.isLoading, !harness.cronUnavailable {
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
            .disabled(harness.cronUnavailable || harness.runner == nil || harness.draft != nil)
            Button {
                guard let id = harness.selectionID, let job = harness.jobs.first(where: { $0.id == id }) else { return }
                Task { await harness.delete(job) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(harness.selectionID == nil)
            Button {
                guard let id = harness.selectionID, let job = harness.jobs.first(where: { $0.id == id }) else { return }
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
                onSave: { schedule, command in
                    Task { await harness.commitAdd(schedule: schedule, command: command) }
                },
                onCancel: { harness.cancelAdd() }
            )
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if let id = harness.selectionID, let job = harness.jobs.first(where: { $0.id == id }) {
            JobEditor(job: job) { schedule, command in
                Task { await harness.update(job, schedule: schedule, command: command) }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ContentUnavailableView("Select a job", systemImage: "sidebar.right")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

}

private struct DraftJobEditor: View {
    @Binding var draft: CronDraft
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    var body: some View {
        Form {
            Section("New cron job") {
                TextField("Schedule (e.g. */5 * * * *)", text: $draft.schedule)
                    .font(.system(.body, design: .monospaced))
                TextField("Command", text: $draft.command)
            }
            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button("Add") {
                    onSave(draft.schedule, draft.command)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(
                    draft.schedule.trimmingCharacters(in: .whitespaces).isEmpty
                    || draft.command.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
        }
    }
}

private struct JobEditor: View {
    let job: CronJob
    let onSave: (String, String) -> Void

    @State private var schedule: String
    @State private var command: String

    init(job: CronJob, onSave: @escaping (String, String) -> Void) {
        self.job = job
        self.onSave = onSave
        self._schedule = State(initialValue: job.schedule)
        self._command = State(initialValue: job.command)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("ID") {
                    Text(job.id).font(.system(.body, design: .monospaced))
                }
                TextField("Schedule", text: $schedule)
                    .font(.system(.body, design: .monospaced))
                TextField("Command", text: $command)
                if let lastRun = job.lastRun {
                    LabeledContent("Last Run") {
                        Text(lastRun, style: .relative)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Save") {
                    onSave(schedule, command)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(
                    schedule.trimmingCharacters(in: .whitespaces).isEmpty
                    || command.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
        }
        .id(job.id)
    }
}

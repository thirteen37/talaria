import HermesKit
import SwiftUI

/// Step 2 of the incoming-share hand-off, presented inside the target profile's
/// window (which already owns the dashboard connection). Lists that profile's
/// sessions plus a "New Session" option; picking one opens/creates it and
/// prefills its composer with the staged text + images — it does **not** send,
/// so the user reviews before submitting. Reuses the window's existing
/// `SessionsStore`/`DashboardClient` rather than building a parallel harness.
struct IncomingShareSessionSheet: View {
    let harness: ServerWindowHarness
    let route: PendingShareRoute
    /// Called after a successful prefill or a cancel — clears the share flow.
    let onComplete: () -> Void

    @State private var item: PendingShareItem?
    @State private var sessions: [HermesSessionSummary] = []
    @State private var committing = false
    /// Terminal errors (`.shareGone`/`.noSession`) that replace the picker.
    @State private var errorMessage: String?
    /// Recoverable error (`.notEditable`) shown as an alert *over* the still-usable
    /// list, so the user can pick a different session.
    @State private var recoverableError: String?

    private var store: SessionsStore { harness.store }
    private let pendingStore = PendingShareStore()

    private enum Target { case new, existing(HermesSessionSummary) }
    private enum CommitError: LocalizedError {
        case shareGone, noSession, notEditable
        var errorDescription: String? {
            switch self {
            case .shareGone: return "The shared item is no longer available."
            case .noSession: return "Couldn’t open a session to add the shared content to."
            case .notEditable: return "That session is read-only and can’t accept shared content. Pick another session or start a new one."
            }
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add to \(harness.profile.name)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { cancel() }
                            .help("Discard the shared item")
                            .disabled(committing)
                    }
                }
                .interactiveDismissDisabled(committing)
                .alert(
                    "Read-Only Session",
                    isPresented: Binding(
                        get: { recoverableError != nil },
                        set: { if !$0 { recoverableError = nil } }
                    ),
                    presenting: recoverableError
                ) { _ in
                    Button("OK", role: .cancel) {}
                } message: { message in
                    Text(message)
                }
        }
        // Re-runs when the dashboard connection comes online (nil → non-nil).
        .task(id: harness.dashboardClient != nil) { await load() }
    }

    @ViewBuilder private var content: some View {
        if committing {
            ProgressView("Adding…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView(
                "Couldn’t Add Share",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else {
            List {
                if let item { previewSection(item) }

                Section {
                    Button {
                        Task { await commit(.new) }
                    } label: {
                        Label("New Session", systemImage: "square.and.pencil")
                    }
                    .help("Start a new session prefilled with the shared content")
                    // Creating a session needs the dashboard/gateway; gating avoids
                    // a tap-before-connected dead-end (matches the sessions section).
                    .disabled(harness.dashboardClient == nil)
                }

                if harness.dashboardClient == nil {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Connecting to \(harness.profile.name)…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !sessions.isEmpty {
                    Section("Existing Sessions") {
                        ForEach(sessions) { summary in
                            Button {
                                Task { await commit(.existing(summary)) }
                            } label: {
                                sessionRow(summary)
                            }
                            .help("Add the shared content to “\(label(summary))”")
                        }
                    }
                }
            }
        }
    }

    private func previewSection(_ item: PendingShareItem) -> some View {
        Section("Sharing") {
            if let text = item.text, !text.isEmpty {
                Text(text)
                    .lineLimit(3)
                    .font(.callout)
            }
            if !item.imageFiles.isEmpty {
                Label(
                    item.imageFiles.count == 1 ? "1 image" : "\(item.imageFiles.count) images",
                    systemImage: "photo"
                )
                .foregroundStyle(.secondary)
            }
        }
    }

    private func sessionRow(_ summary: HermesSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label(summary))
                .font(.body)
            // `cwd` isn't populated by the list endpoint (always nil); the
            // conversation `preview` is, and better identifies a session.
            if let preview = summary.preview, !preview.isEmpty {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(.rect)
    }

    private func label(_ summary: HermesSessionSummary) -> String {
        summary.title.isEmpty ? "Untitled session" : summary.title
    }

    // MARK: - Load

    private func load() async {
        if item == nil {
            item = try? await pendingStore.pendingItem(id: route.id)
        }
        guard let client = harness.dashboardClient else { return }
        if let response = try? await client.listSessions(limit: 100, minMessages: 1) {
            // Only offer sessions that open with an editable composer — a
            // read-only session (e.g. a one-shot `cli` run) would swallow the
            // prefill silently. See `SessionsStore.canPrefill`.
            sessions = response.sessions
                .map(HermesSessionSummary.init)
                .filter { store.canPrefill(source: $0.source) }
        }
    }

    // MARK: - Commit

    private func commit(_ target: Target) async {
        committing = true
        defer { committing = false }
        do {
            guard let staged = try await pendingStore.pendingItem(id: route.id) else {
                throw CommitError.shareGone
            }

            let sessionId: SessionId
            switch target {
            case .new:
                let before = store.selection
                await store.openNew()
                guard let id = store.selection, id != before else { throw CommitError.noSession }
                sessionId = id
            case let .existing(summary):
                await store.openExisting(summary)
                sessionId = summary.id
            }

            // Normalize off the main actor — decode/downscale is CPU-bound.
            let raw = (try? await pendingStore.loadImageData(for: staged)) ?? []
            let attachments: [ComposerAttachment] = await Task.detached {
                raw.compactMap { ImageNormalizer.normalize($0.data, displayName: nil) }
            }.value

            // Refuses (and keeps the staged share) if the opened session turned
            // out read-only — the nil-source edge the list filter can't catch.
            guard store.prefillComposerFromShare(
                sessionId: sessionId,
                text: staged.text,
                attachments: attachments
            ) else {
                throw CommitError.notEditable
            }

            // Dismiss; the presenter's `onDismiss` consumes the staged share and
            // clears the coordinator (covers Cancel and swipe-to-dismiss too).
            onComplete()
        } catch CommitError.notEditable {
            // Recoverable: keep the share and the list up so the user can pick a
            // different (editable) session — an alert, not a terminal error view.
            recoverableError = CommitError.notEditable.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func cancel() {
        // Cleanup (consume + finish) runs in the presenter's `onDismiss`.
        onComplete()
    }
}

import HermesKit
import SwiftUI

/// Editor for one built-in memory file (`MEMORY.md` / `USER.md`). Reads and
/// writes the raw text directly on disk — local or over SSH via the window's
/// write-capable transfer — since Hermes exposes no dashboard route for their
/// contents. Mirrors ``SoulEditingState`` but is disk-backed in both directions.
@MainActor
@Observable
final class MemoryFileEditor: Identifiable {
    let file: HermesMemoryFile
    nonisolated var id: String { file.rawValue }

    var text = ""
    /// On-disk content captured at the last successful load/save, for the dirty
    /// check and the read-before-write overwrite guard.
    private(set) var original = ""
    var isLoading = false
    var lastError: String?
    /// Top-of-window banner hub (window-scoped); optional so a missing host
    /// degrades to no-op. Each file keys its banners by name so MEMORY.md and
    /// USER.md errors don't clobber each other.
    var banners: BannerCenter?
    private var bannerKey: String { "memory.\(file.fileName)" }
    /// Set when `save()` finds the on-disk file changed since load (the agent
    /// likely rewrote it). The view raises an overwrite confirmation; `saveForced`
    /// proceeds.
    var conflictPending = false

    private let profile: ServerProfile
    private let profileName: String
    private let transfer: RemoteSnapshotTransfer?

    init(file: HermesMemoryFile, profile: ServerProfile, profileName: String, transfer: RemoteSnapshotTransfer?) {
        self.file = file
        self.profile = profile
        self.profileName = profileName
        self.transfer = transfer
    }

    var isDirty: Bool { text != original }
    var canSave: Bool { isDirty && !isLoading }
    var charCount: Int { text.count }
    var isOverCap: Bool { text.count > file.charCap }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let content = try await readContent()
            text = content
            original = content
            lastError = nil
            conflictPending = false
            banners?.dismiss(key: bannerKey)
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    /// Saves the buffer, guarding against clobbering a concurrent agent write:
    /// re-reads the file first and, if it diverged from what we loaded, defers to
    /// the view's overwrite confirmation instead of writing.
    func save() async {
        guard canSave else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let onDisk = try await readContent()
            if onDisk != original {
                conflictPending = true
                return
            }
            try await writeContent(text)
            original = text
            lastError = nil
            banners?.surfaceSuccess(bannerKey, "\(file.fileName) saved")
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    /// Writes the buffer unconditionally — used after the user confirms the
    /// overwrite in the conflict dialog.
    func saveForced() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await writeContent(text)
            original = text
            lastError = nil
            conflictPending = false
            banners?.surfaceSuccess(bannerKey, "\(file.fileName) saved")
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    /// Reverts to the persisted state (Discard).
    func discard() {
        text = original
    }

    /// Clears this file's top-of-window banner — called when the Memory surface
    /// goes away so a stale error doesn't linger over the next surface.
    func dismissBanner() {
        banners?.dismiss(key: bannerKey)
    }

    private func readContent() async throws -> String {
        try await HermesMemoryStore.read(profile: profile, profileName: profileName, file: file, transfer: transfer)
    }

    private func writeContent(_ content: String) async throws {
        try await HermesMemoryStore.write(content, profile: profile, profileName: profileName, file: file, transfer: transfer)
    }
}

/// Owns the two memory-file editors, the read-only provider line, and the
/// unsaved-edits navigation guard. Built once per window; the editors read/write
/// disk directly, so this works even with the dashboard down — only the provider
/// line needs the dashboard client.
@MainActor
@Observable
final class MemoryHarness {
    let editors: [MemoryFileEditor]
    var selection: HermesMemoryFile?
    /// Active memory provider from `GET /api/memory`; "" = built-in.
    var activeProvider = ""
    /// False when the dashboard is unreachable or too old to report status, so
    /// the provider line degrades to "Unknown" rather than wrongly claiming
    /// built-in.
    var providerKnown = false
    var isLoadingProvider = false

    private let clientProvider: @MainActor () -> DashboardClient?

    init(profile: ServerProfile, profileName: String, transfer: RemoteSnapshotTransfer?, client: @escaping @MainActor () -> DashboardClient?) {
        self.editors = [
            MemoryFileEditor(file: .memory, profile: profile, profileName: profileName, transfer: transfer),
            MemoryFileEditor(file: .user, profile: profile, profileName: profileName, transfer: transfer),
        ]
        self.clientProvider = client
    }

    func editor(for file: HermesMemoryFile) -> MemoryFileEditor {
        editors.first { $0.file == file } ?? editors[0]
    }

    /// Clears both files' top-of-window banners — called when the Memory surface
    /// goes away so a stale error doesn't linger over the next surface.
    func dismissBanners() {
        editors.forEach { $0.dismissBanner() }
    }

    var selected: MemoryFileEditor? {
        selection.map { editor(for: $0) }
    }

    var isBuiltIn: Bool { providerKnown && activeProvider.isEmpty }

    /// Provider line text for the primary list footer.
    var providerLabel: String {
        if !providerKnown { return "Unknown" }
        return activeProvider.isEmpty ? "Built-in" : activeProvider
    }

    /// Loads both files from disk and (best-effort) the provider status.
    func load() async {
        for editor in editors {
            await editor.load()
        }
        await loadProvider()
    }

    func loadFiles() async {
        for editor in editors {
            await editor.load()
        }
    }

    func loadProvider() async {
        guard let client = clientProvider() else {
            providerKnown = false
            return
        }
        isLoadingProvider = true
        defer { isLoadingProvider = false }
        do {
            let status = try await client.getMemory()
            activeProvider = status.active
            providerKnown = true
        } catch {
            // Older Hermes (no route) or dashboard down: keep editing, show
            // "Unknown" instead of a wrong "Built-in".
            providerKnown = false
        }
    }

    var lastError: String? {
        editors.compactMap(\.lastError).first
    }
}

/// The **Memory** tab: a two-row list (`MEMORY.md`, `USER.md`) plus a read-only
/// provider line, and a markdown editor with a soft char-cap counter and Save.
struct MemoryEditorView: View {
    let windowHarness: ServerWindowHarness

    @Environment(BannerCenter.self) private var banners: BannerCenter?

    @State private var harness: MemoryHarness?
    @State private var pendingNavigation: PendingNavigation?

    private var client: DashboardClient? { windowHarness.dashboardClient }

    private enum PendingNavigation {
        case select(HermesMemoryFile?)
        case refresh
    }

    var body: some View {
        Group {
            if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Memory")
        // Clear both files' pinned errors when the surface leaves so they don't
        // linger over the next surface.
        .onDisappear { harness?.dismissBanners() }
        .task {
            if harness == nil {
                let h = MemoryHarness(
                    profile: windowHarness.profile,
                    profileName: windowHarness.hermesProfileName,
                    transfer: windowHarness.snapshotTransfer,
                    client: { [weak windowHarness] in windowHarness?.dashboardClient }
                )
                h.selection = .memory
                h.editors.forEach { $0.banners = banners }
                harness = h
                await h.load()
            }
        }
        .onChange(of: client != nil) { _, hasClient in
            guard hasClient else { return }
            Task { await harness?.loadProvider() }
        }
    }

    @ViewBuilder
    private func content(harness: MemoryHarness) -> some View {
        PlatformSplit(showsSecondary: harness.selection != nil) {
            primaryPane(harness: harness)
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        } secondary: {
            detailPane(harness: harness)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { toolbar(harness: harness) }
        // Load/save errors route to the top-of-window strip (per file); there's
        // no in-surface capability warning here, so no `.manageBanner`.
        .confirmationDialog(
            "Unsaved changes",
            isPresented: Binding(
                get: { pendingNavigation != nil },
                set: { if !$0 { pendingNavigation = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingNavigation
        ) { action in
            if let editor = harness.selected, editor.canSave {
                Button("Save") {
                    saveThenNavigate(editor: editor, harness: harness, action: action)
                    pendingNavigation = nil
                }
            }
            Button("Discard", role: .destructive) {
                harness.selected?.discard()
                perform(action, harness: harness)
                pendingNavigation = nil
            }
            Button("Cancel", role: .cancel) { pendingNavigation = nil }
        } message: { _ in
            Text("You have unsaved changes to \(harness.selected?.file.fileName ?? "this file").")
        }
    }

    // MARK: - Primary pane

    @ViewBuilder
    private func primaryPane(harness: MemoryHarness) -> some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { harness.selection },
                set: { attemptNavigate(.select($0), harness: harness) }
            )) {
                ForEach(harness.editors) { editor in
                    MemoryFileRow(editor: editor)
                        .tag(editor.file)
                }
            }

            Divider()
            HStack(spacing: 6) {
                Text("Provider")
                    .foregroundStyle(.secondary)
                Text(harness.providerLabel)
                    .fontWeight(.medium)
                if harness.isLoadingProvider {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private func detailPane(harness: MemoryHarness) -> some View {
        if let editor = harness.selected {
            MemoryFileDetail(
                editor: editor,
                externalProvider: harness.isBuiltIn || !harness.providerKnown ? nil : harness.activeProvider
            )
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            EmptyView()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbar(harness: MemoryHarness) -> some ToolbarContent {
        ToolbarItem {
            Button {
                attemptNavigate(.refresh, harness: harness)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(harness.selected?.isLoading ?? false)
            .help("Reload the memory files from disk")
        }
    }

    // MARK: - Navigation guard

    private func attemptNavigate(_ action: PendingNavigation, harness: MemoryHarness) {
        if harness.selected?.isDirty == true {
            pendingNavigation = action
        } else {
            perform(action, harness: harness)
        }
    }

    private func perform(_ action: PendingNavigation, harness: MemoryHarness) {
        switch action {
        case let .select(file):
            harness.selection = file
        case .refresh:
            Task { await harness.loadFiles(); await harness.loadProvider() }
        }
    }

    private func saveThenNavigate(editor: MemoryFileEditor, harness: MemoryHarness, action: PendingNavigation) {
        Task {
            await editor.save()
            // A save that hit an on-disk conflict leaves the user on this file to
            // resolve it; only navigate when the write actually landed.
            if editor.lastError == nil, !editor.conflictPending {
                perform(action, harness: harness)
            }
        }
    }
}

/// One file row: name + a live char count against the soft cap.
private struct MemoryFileRow: View {
    let editor: MemoryFileEditor

    var body: some View {
        HStack {
            Text(editor.file.fileName)
            Spacer()
            Text("\(editor.charCount)/\(editor.file.charCap)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(editor.isOverCap ? .red : .secondary)
        }
    }
}

/// Editable detail for one memory file.
private struct MemoryFileDetail: View {
    @Bindable var editor: MemoryFileEditor
    /// Non-nil when an external memory provider is active, so the built-in files
    /// may be inactive.
    let externalProvider: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(editor.file.fileName)
                    .font(.headline)
                Spacer()
                Text("\(editor.charCount)/\(editor.file.charCap) chars")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(editor.isOverCap ? .red : .secondary)
            }

            Text("Hermes's agent manages this file; your edits take effect at the next session start and may overwrite — or be overwritten by — the agent's own updates.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let externalProvider {
                Text("An external memory provider (\(externalProvider)) is active; these built-in files may be inactive.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HighlightingTextEditor.markdown(text: $editor.text)
                .frame(minHeight: 240, maxHeight: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                )

            // Load/save errors surface in the view's top banner (harness.lastError);
            // this inline note is just the soft over-cap hint.
            if editor.isOverCap {
                Text("Over the agent's \(editor.file.charCap)-char budget — still saved, but the agent may trim it.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    Task { await editor.save() }
                } label: {
                    Label("Save", systemImage: "checkmark.circle")
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!editor.canSave)
                .help("Save \(editor.file.fileName) to disk")

                if editor.isLoading { ProgressView().controlSize(.small) }
            }

            Spacer()
        }
        .confirmationDialog(
            "File changed on disk",
            isPresented: $editor.conflictPending,
            titleVisibility: .visible
        ) {
            Button("Overwrite", role: .destructive) {
                Task { await editor.saveForced() }
            }
            Button("Cancel", role: .cancel) { editor.conflictPending = false }
        } message: {
            Text("\(editor.file.fileName) changed on disk since you opened it — likely the agent updated it. Overwrite with your edits?")
        }
    }
}

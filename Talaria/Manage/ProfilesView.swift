import HermesKit
import SwiftUI

/// Editor draft for the secondary pane — either cloning an existing profile or
/// renaming one. Both capture a single free-form `newName` field.
struct ProfileDraft: Equatable {
    enum Mode: Equatable {
        /// Clone `source` into a brand-new profile.
        case clone(source: String)
        /// Rename `original` to the entered name.
        case rename(original: String)
    }

    var mode: Mode
    var newName: String = ""
}

@MainActor
@Observable
final class ProfilesHarness {
    var profiles: [HermesProfileInfo] = []
    var lastError: String?
    var isLoading: Bool = false
    var selectionID: HermesProfileInfo.ID?
    var draft: ProfileDraft?

    private let client: DashboardClient?
    private let runner: HermesAdminRunning?
    /// Invoked after any successful mutation so the window can refresh its
    /// sidebar switcher and reconcile the active `-p <name>` if it vanished.
    private let onProfilesChanged: () -> Void

    init(
        client: DashboardClient?,
        runner: HermesAdminRunning?,
        onProfilesChanged: @escaping () -> Void
    ) {
        self.client = client
        self.runner = runner
        self.onProfilesChanged = onProfilesChanged
    }

    var selectedProfile: HermesProfileInfo? {
        guard let id = selectionID else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Dashboard-first / CLI-fallback / default-degrade — the same ladder the
    /// window uses to populate the sidebar switcher.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        if let client {
            do {
                let list = try await client.listProfiles()
                profiles = list.map {
                    HermesProfileInfo(name: $0.name, isDefault: $0.isDefault, model: $0.model)
                }
                lastError = nil
                return
            } catch {
                // Fall through to the CLI source.
            }
        }
        if let runner {
            do {
                profiles = try await HermesProfiles.list(runner: runner)
                lastError = nil
                return
            } catch {
                // Fall through to the default-only degrade.
            }
        }
        profiles = [HermesProfileInfo(name: HermesProfiles.defaultProfileName, isDefault: true, status: nil)]
    }

    // MARK: - Editor lifecycle

    func beginClone(source: String) {
        draft = ProfileDraft(mode: .clone(source: source))
    }

    func beginRename(original: String) {
        draft = ProfileDraft(mode: .rename(original: original), newName: original)
    }

    func cancelEdit() { draft = nil }

    // MARK: - Mutations

    /// Clones `source` into `rawName`. The dashboard API can only clone from
    /// `default`, so a non-default source goes straight to the CLI; cloning
    /// from default tries the dashboard first and falls back to the CLI.
    func clone(source: String, newName rawName: String) async {
        if let message = validateNewName(rawName) { lastError = message; return }
        let name = normalized(rawName)
        let message: String?
        if source == HermesProfiles.defaultProfileName {
            message = await runWrite(
                dashboard: { try await $0.createProfile(name: name, cloneFromDefault: true, noSkills: false) },
                cli: { try await HermesProfiles.create(runner: $0, name: name, cloneFrom: HermesProfiles.defaultProfileName) }
            )
        } else {
            guard let runner else {
                lastError = "Cloning a non-default profile requires the Hermes CLI."
                return
            }
            do {
                try await HermesProfiles.create(runner: runner, name: name, cloneFrom: source)
                message = nil
            } catch {
                message = error.localizedDescription
            }
        }
        await finishWrite(message)
    }

    func rename(from original: String, to rawName: String) async {
        guard original != HermesProfiles.defaultProfileName else {
            lastError = "The default profile cannot be renamed."
            return
        }
        if let message = validateNewName(rawName) { lastError = message; return }
        let name = normalized(rawName)
        let message = await runWrite(
            dashboard: { try await $0.renameProfile(name: original, newName: name) },
            cli: { try await HermesProfiles.rename(runner: $0, from: original, to: name) }
        )
        await finishWrite(message)
    }

    func delete(name: String) async {
        guard name != HermesProfiles.defaultProfileName else {
            lastError = "The default profile cannot be deleted."
            return
        }
        let message = await runWrite(
            dashboard: { try await $0.deleteProfile(name: name) },
            cli: { try await HermesProfiles.delete(runner: $0, name: name) }
        )
        await finishWrite(message)
    }

    // MARK: - Plumbing

    /// Runs a write dashboard-first, falling back to the CLI when the dashboard
    /// is absent or fails. On total failure surfaces the dashboard error (its
    /// HTTP 400 `detail` is more informative than the CLI's stderr) when a
    /// dashboard attempt was actually made. Returns nil on success.
    private func runWrite(
        dashboard: (DashboardClient) async throws -> Void,
        cli: (HermesAdminRunning) async throws -> Void
    ) async -> String? {
        var dashboardError: Error?
        if let client {
            do { try await dashboard(client); return nil }
            catch { dashboardError = error }
        }
        if let runner {
            do { try await cli(runner); return nil }
            catch { return (dashboardError ?? error).localizedDescription }
        }
        if let dashboardError { return dashboardError.localizedDescription }
        return "No dashboard or CLI available to manage profiles."
    }

    private func finishWrite(_ message: String?) async {
        if let message {
            lastError = message
            return
        }
        lastError = nil
        draft = nil
        await refresh()
        onProfilesChanged()
    }

    /// Lowercased, whitespace-trimmed name as sent to the backend. Hermes
    /// normalizes to lowercase itself, but doing it here keeps the optimistic
    /// validation and the request in agreement.
    private func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Light client-side check; the backend remains the source of truth for
    /// reserved/colliding names. Returns an error message or nil when valid.
    private func validateNewName(_ raw: String) -> String? {
        let name = normalized(raw)
        guard !name.isEmpty else { return "Profile name cannot be empty." }
        guard name != HermesProfiles.defaultProfileName else { return "“default” is a reserved name." }
        guard name.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil else {
            return "Use lowercase letters, digits, “-” or “_”, starting with a letter or digit."
        }
        return nil
    }
}

struct ProfilesView: View {
    let client: DashboardClient?
    let runner: HermesAdminRunning?
    let activeProfile: String
    let hermesVersion: HermesVersion?
    let onProfilesChanged: () -> Void

    @State private var harness: ProfilesHarness?
    @State private var profileToDelete: HermesProfileInfo?

    init(
        client: DashboardClient?,
        runner: HermesAdminRunning?,
        activeProfile: String = HermesProfiles.defaultProfileName,
        hermesVersion: HermesVersion? = nil,
        onProfilesChanged: @escaping () -> Void = {}
    ) {
        self.client = client
        self.runner = runner
        self.activeProfile = activeProfile
        self.hermesVersion = hermesVersion
        self.onProfilesChanged = onProfilesChanged
    }

    var body: some View {
        Group {
            if client == nil {
                ContentUnavailableView(
                    "Dashboard not ready",
                    systemImage: "square.stack.3d.up",
                    description: Text("Waiting for the Hermes dashboard to come online.")
                )
            } else if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Profiles")
        // Keyed on client availability so the harness is built when the
        // dashboard finishes booting and `client` flips non-nil, not only on
        // first appear (matching Cron).
        .task(id: client != nil) {
            guard let client else { harness = nil; return }
            if harness != nil { return }
            let h = ProfilesHarness(client: client, runner: runner, onProfilesChanged: onProfilesChanged)
            harness = h
            await h.refresh()
        }
    }

    @ViewBuilder
    private func content(harness: ProfilesHarness) -> some View {
        PlatformSplit(showsSecondary: harness.draft != nil) {
            profilesTable(harness: harness)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        } secondary: {
            editorPane(harness: harness)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { toolbar(harness: harness) }
        .manageBanner(
            harness.lastError ?? capabilityBanner(
                .requiresDashboard,
                feature: "Profile management via Hermes dashboard",
                version: hermesVersion
            ),
            severity: harness.lastError != nil ? .error : .warning
        )
        .alert(
            "Delete profile?",
            isPresented: Binding(
                get: { profileToDelete != nil },
                set: { if !$0 { profileToDelete = nil } }
            ),
            presenting: profileToDelete
        ) { profile in
            Button("Delete", role: .destructive) {
                Task { await harness.delete(name: profile.name) }
            }
            Button("Cancel", role: .cancel) { profileToDelete = nil }
        } message: { profile in
            Text("“\(profile.name)” and its config, memories, and skills will be permanently removed. This cannot be undone.")
        }
    }

    @ViewBuilder
    private func profilesTable(harness: ProfilesHarness) -> some View {
        Table(harness.profiles, selection: Binding(
            get: { harness.selectionID },
            set: { harness.selectionID = $0 }
        )) {
            TableColumn("Name") { profile in
                HStack(spacing: 6) {
                    Text(profile.name)
                    if profile.name == activeProfile {
                        Text("active")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
            }
            TableColumn("Default") { profile in
                if profile.isDefault {
                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                }
            }
            .width(60)
            TableColumn("Model") { profile in
                Text(profile.model ?? "—")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .overlay {
            if harness.profiles.isEmpty, !harness.isLoading {
                ContentUnavailableView("No profiles", systemImage: "square.stack.3d.up")
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(harness: ProfilesHarness) -> some ToolbarContent {
        ToolbarItemGroup {
            Button { Task { await harness.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(harness.isLoading)
            Button {
                guard let profile = harness.selectedProfile else { return }
                harness.beginClone(source: profile.name)
            } label: {
                Label("Clone", systemImage: "plus.square.on.square")
            }
            .disabled(harness.selectionID == nil)
            Button {
                guard let profile = harness.selectedProfile else { return }
                harness.beginRename(original: profile.name)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .disabled(renameDeleteDisabled(harness))
            Button {
                profileToDelete = harness.selectedProfile
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(renameDeleteDisabled(harness))
        }
    }

    /// Rename/Delete act on a single named profile and `default` is immutable,
    /// so both are gated on a non-default selection.
    private func renameDeleteDisabled(_ harness: ProfilesHarness) -> Bool {
        guard let profile = harness.selectedProfile else { return true }
        return profile.isDefault || profile.name == HermesProfiles.defaultProfileName
    }

    // Rendered only while a clone/rename draft is active — `PlatformSplit`'s
    // `showsSecondary` gate hides this pane entirely otherwise.
    @ViewBuilder
    private func editorPane(harness: ProfilesHarness) -> some View {
        if harness.draft != nil {
            ProfileDraftEditor(
                draft: Binding(
                    get: { harness.draft ?? ProfileDraft(mode: .clone(source: HermesProfiles.defaultProfileName)) },
                    set: { harness.draft = $0 }
                ),
                onSave: { draft in
                    switch draft.mode {
                    case let .clone(source):
                        Task { await harness.clone(source: source, newName: draft.newName) }
                    case let .rename(original):
                        Task { await harness.rename(from: original, to: draft.newName) }
                    }
                },
                onCancel: { harness.cancelEdit() }
            )
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct ProfileDraftEditor: View {
    @Binding var draft: ProfileDraft
    let onSave: (ProfileDraft) -> Void
    let onCancel: () -> Void

    private var title: String {
        switch draft.mode {
        case let .clone(source): return "Clone “\(source)”"
        case let .rename(original): return "Rename “\(original)”"
        }
    }

    private var actionLabel: String {
        switch draft.mode {
        case .clone: return "Clone"
        case .rename: return "Rename"
        }
    }

    var body: some View {
        Form {
            Section(title) {
                TextField("New name", text: $draft.newName)
                    .textFieldStyle(.roundedBorder)
                Text("Lowercase letters, digits, “-” or “_”. Starts with a letter or digit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button(actionLabel) { onSave(draft) }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(draft.newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

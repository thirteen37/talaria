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
    /// Top-of-window banner hub (window-scoped). Hard errors route here keyed by
    /// the surface id so they render full-width across the top. Optional so a
    /// missing host degrades to no-op.
    var banners: BannerCenter?
    var isLoading: Bool = false
    var selectionID: HermesProfileInfo.ID?
    var draft: ProfileDraft?

    private let client: DashboardClient?
    /// Invoked after any successful mutation so the window can refresh its
    /// sidebar switcher and reconcile the active `-p <name>` if it vanished.
    private let onProfilesChanged: () -> Void

    init(
        client: DashboardClient?,
        onProfilesChanged: @escaping () -> Void
    ) {
        self.client = client
        self.onProfilesChanged = onProfilesChanged
    }

    var selectedProfile: HermesProfileInfo? {
        guard let id = selectionID else { return nil }
        return profiles.first { $0.id == id }
    }

    /// The dashboard API can only clone from `default`, so cloning is offered
    /// only when the default profile is selected.
    var canClone: Bool {
        guard let profile = selectedProfile else { return false }
        return profile.isDefault || profile.name == HermesProfiles.defaultProfileName
    }

    /// Dashboard-only. The dashboard reports clean names + a structured
    /// `is_default` flag, so this never leaks the CLI `profile list` table's
    /// `◆` default-marker glyph into a name. On failure the error is surfaced
    /// (no CLI fallback, no `default`-only degrade) so the user sees a banner
    /// rather than silent CLI-parsed data. `client == nil` is handled upstream
    /// by the view's "Dashboard not ready" state.
    func refresh() async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await client.listProfiles()
            profiles = list.map {
                HermesProfileInfo(name: $0.name, isDefault: $0.isDefault, model: $0.model)
            }
            lastError = nil
            banners?.dismiss(key: "profiles")
        } catch {
            let message = error.localizedDescription
            lastError = message
            banners?.surfaceError("profiles", message)
        }
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

    /// Clones into a new profile `rawName`. The dashboard API can only clone
    /// from `default`, so the UI gates Clone to the default row and this always
    /// seeds from default.
    func clone(newName rawName: String) async {
        if let message = validateNewName(rawName) {
            lastError = message
            banners?.surfaceError("profiles", message)
            return
        }
        let name = normalized(rawName)
        let message = await runWrite { try await $0.createProfile(name: name, cloneFromDefault: true, noSkills: false) }
        await finishWrite(message)
    }

    func rename(from original: String, to rawName: String) async {
        guard original != HermesProfiles.defaultProfileName else {
            let message = "The default profile cannot be renamed."
            lastError = message
            banners?.surfaceError("profiles", message)
            return
        }
        if let message = validateNewName(rawName) {
            lastError = message
            banners?.surfaceError("profiles", message)
            return
        }
        let name = normalized(rawName)
        let message = await runWrite { try await $0.renameProfile(name: original, newName: name) }
        await finishWrite(message)
    }

    func delete(name: String) async {
        guard name != HermesProfiles.defaultProfileName else {
            let message = "The default profile cannot be deleted."
            lastError = message
            banners?.surfaceError("profiles", message)
            return
        }
        let message = await runWrite { try await $0.deleteProfile(name: name) }
        await finishWrite(message)
    }

    // MARK: - Plumbing

    /// Runs a write against the dashboard. Returns nil on success, the
    /// dashboard error's description on failure (its HTTP 400 `detail` is the
    /// informative message), or a "no dashboard" message when `client == nil`.
    private func runWrite(
        _ dashboard: (DashboardClient) async throws -> Void
    ) async -> String? {
        guard let client else { return "No dashboard available to manage profiles." }
        do { try await dashboard(client); return nil }
        catch { return error.localizedDescription }
    }

    private func finishWrite(_ message: String?) async {
        if let message {
            lastError = message
            banners?.surfaceError("profiles", message)
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
    let activeProfile: String
    let hermesVersion: HermesVersion?
    let onProfilesChanged: () -> Void

    /// Window's top-of-window banner hub. Optional so a host that doesn't supply
    /// one degrades to no-op (hard errors then simply don't render).
    @Environment(BannerCenter.self) private var banners: BannerCenter?
    /// Window navigator: an `EntityLink` to a Hermes profile selects its row when
    /// this page lands. Optional so the page renders without one.
    @Environment(WindowNavigator.self) private var navigator: WindowNavigator?

    @State private var harness: ProfilesHarness?
    @State private var profileToDelete: HermesProfileInfo?

    init(
        client: DashboardClient?,
        activeProfile: String = HermesProfiles.defaultProfileName,
        hermesVersion: HermesVersion? = nil,
        onProfilesChanged: @escaping () -> Void = {}
    ) {
        self.client = client
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
        .dismissesBanner("profiles", from: banners)
        // Keyed on client availability so the harness is built when the
        // dashboard finishes booting and `client` flips non-nil, not only on
        // first appear (matching Cron).
        .task(id: client != nil) {
            guard let client else { harness = nil; return }
            if harness != nil { consumeFocus(harness: harness!); return }
            let h = ProfilesHarness(client: client, onProfilesChanged: onProfilesChanged)
            h.banners = banners
            harness = h
            await h.refresh()
            consumeFocus(harness: h)
        }
        // Re-entering this page (focus set before it appeared) and a profile
        // EntityLink tapped while already on it both select the row.
        .onAppear { if let harness { consumeFocus(harness: harness) } }
        .onChange(of: navigator?.pendingFocus) { _, _ in
            if let harness { consumeFocus(harness: harness) }
        }
    }

    /// Selects the row named by a pending Hermes-profile focus, then clears it.
    /// Ignores focus aimed at another page.
    private func consumeFocus(harness: ProfilesHarness) {
        guard let ref = navigator?.pendingFocus, case let .hermesProfile(name) = ref else { return }
        if let match = harness.profiles.first(where: { $0.name == name }) {
            harness.selectionID = match.id
        }
        Task { @MainActor in navigator?.pendingFocus = nil }
    }

    @ViewBuilder
    private func content(harness: ProfilesHarness) -> some View {
        PlatformSplit(
            showsSecondary: Binding(
                get: { harness.draft != nil },
                set: { if !$0 { harness.cancelEdit() } }
            ),
            secondaryTitle: editorTitle(harness)
        ) {
            profilesTable(harness: harness)
                .frame(minWidth: Idiom.isPhone ? nil : 360, maxWidth: .infinity, maxHeight: .infinity)
        } secondary: {
            editorPane(harness: harness)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { toolbar(harness: harness) }
        // Hard errors route to the top-of-window strip; only the capability warning stays in-surface.
        .manageBanner(
            capabilityBanner(
                .requiresDashboard,
                feature: "Profile management via Hermes dashboard",
                version: hermesVersion
            ),
            severity: .warning
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
                if let model = profile.model, !model.isEmpty {
                    EntityLink(model, ref: .modelMain, style: .prominent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("—")
                        .foregroundStyle(.secondary)
                }
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
            .disabled(!harness.canClone)
            .help("Create a new profile from default")
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

    /// Title for the pushed iPhone editor page — "Clone …" / "Rename …" matching
    /// the active draft. nil when no draft is active (the pane is hidden).
    private func editorTitle(_ harness: ProfilesHarness) -> String? {
        switch harness.draft?.mode {
        case let .clone(source): return "Clone “\(source)”"
        case let .rename(original): return "Rename “\(original)”"
        case nil: return nil
        }
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
                    case .clone:
                        Task { await harness.clone(newName: draft.newName) }
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

import HermesKit
import SwiftUI

/// Compact iPhone profile editor: a `NavigationStack` list that pushes a
/// single-column detail form. Uses explicit push navigation because a
/// selection-driven `NavigationSplitView` push doesn't fire reliably in a
/// compact-width sheet. Password + Keychain auth via the shared form sections.
struct PhoneProfileEditor: View {
    @Environment(ProfileDirectory.self) private var directory
    /// Settings-local banner hub (hosted by `SettingsTabs`). Optional so a host
    /// without one degrades to no-op.
    @Environment(BannerCenter.self) private var banners: BannerCenter?
    @State private var state = ProfileEditorState()
    /// Drives the NavigationStack so `addNew()` can push the detail view.
    @State private var path: [UUID] = []
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationTitle("Servers")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            addNew()
                            if let pending = state.pendingDraft {
                                path = [pending.id]
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add server")
                        .help("Add a server")
                    }
                    if let onDismiss {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done", action: onDismiss)
                                .help("Close")
                        }
                    }
                }
                .navigationDestination(for: UUID.self) { id in
                    detailView(for: id)
                }
        }
        .task { await reload() }
        // Clear this editor's pinned save error when the surface goes away (tab
        // switch / sheet dismiss) so it doesn't linger over an unrelated Settings
        // tab. Successes are keyless and auto-dismiss, so they're left alone.
        .dismissesBanner("profile", from: banners)
    }

    @ViewBuilder
    private var list: some View {
        List {
            if let pending = state.pendingDraft {
                Section("Unsaved") {
                    NavigationLink(value: pending.id) {
                        row(for: pending, isDraft: true)
                    }
                }
            }
            Section("Configured") {
                if directory.profiles.isEmpty && state.pendingDraft == nil {
                    Text("No servers yet. Tap + to add one.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(directory.profiles) { profile in
                        NavigationLink(value: profile.id) {
                            row(for: profile, isDraft: false)
                        }
                    }
                }
            }
        }
    }

    /// Pushed detail view. Selects the profile into the editor state on appear
    /// so `state.draft` matches the row tapped.
    @ViewBuilder
    private func detailView(for id: UUID) -> some View {
        Group {
            if let draft = state.draft, draft.id == id {
                PhoneProfileDetail(
                    draft: draftBinding(for: id),
                    passwordInput: $state.passwordInput,
                    isPending: state.pendingDraft?.id == id,
                    canSave: canSaveCurrentDraft,
                    onSave: { save() },
                    onDiscard: { discardPending() }
                )
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if state.selection != id {
                state.select(id, in: directory)
            }
        }
    }

    @ViewBuilder
    private func row(for profile: ServerProfile, isDraft: Bool) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(profile.name)
                        .lineLimit(1)
                    if isDraft {
                        Text("Draft")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                Text(profileSubtitle(profile))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: profile.kind == .ssh ? "network" : "desktopcomputer")
        }
    }

    private func profileSubtitle(_ profile: ServerProfile) -> String {
        switch profile.kind {
        case .local: return "Local"
        case .ssh:
            if let host = profile.host, !host.isEmpty {
                return profile.user.map { "\($0)@\(host)" } ?? host
            }
            return "SSH"
        }
    }

    private func draftBinding(for id: UUID) -> Binding<ServerProfile> {
        Binding(
            get: { state.draft ?? ServerProfile(id: id, name: "", kind: .ssh) },
            set: { newValue in
                if state.draft?.id == id {
                    state.updateDraft(newValue)
                }
            }
        )
    }

    private func reload() async {
        await directory.reload()
        state.resetIfMissing(in: directory)
        if state.selection == nil, let first = directory.profiles.first {
            state.select(first.id, in: directory)
        }
    }

    private func addNew() {
        let profile = ServerProfile(name: "New Server", kind: .ssh)
        state.pendingDraft = profile
        state.select(profile.id, in: directory)
    }

    private func discardPending() {
        guard let pending = state.pendingDraft else { return }
        state.pendingDraft = nil
        state.probeStates.removeValue(forKey: pending.id)
        state.validatedThisSession.remove(pending.id)
        state.select(directory.profiles.first?.id, in: directory)
        // Pop back to the list so the user isn't stuck on a detail page bound
        // to a profile that no longer exists in state.
        path.removeAll()
    }

    /// The full saveability check against the lifted password state — mirrors
    /// the desktop editor's helper.
    private var canSaveCurrentDraft: Bool {
        guard let draft = state.draft else { return false }
        return ProfileEditorState.isSaveable(
            draft,
            hasPasswordInput: !state.passwordInput.isEmpty,
            passwordChanged: state.passwordChanged,
            baseCanSave: state.baseCanSave(draft, in: directory)
        )
    }

    private func save() {
        guard var draft = state.draft, canSaveCurrentDraft else { return }
        if draft.authMethod == .password {
            if state.passwordChanged, !state.passwordInput.isEmpty {
                let reference = draft.passwordKeychainReference ?? UUID().uuidString
                do {
                    try PasswordKeychain.set(reference: reference, password: state.passwordInput)
                    draft.passwordKeychainReference = reference
                } catch {
                    let message = "Couldn't save password to Keychain: \(error.localizedDescription)"
                    directory.lastError = message
                    banners?.surfaceError("profile", message)
                    return
                }
            }
        } else if let reference = draft.passwordKeychainReference {
            try? PasswordKeychain.delete(reference: reference)
            draft.passwordKeychainReference = nil
        }
        let saved = draft
        Task {
            // Clear first so the post-upsert check reflects *this* save's outcome,
            // not a stale failure from a previous attempt.
            directory.lastError = nil
            await directory.upsert(saved)
            if let error = directory.lastError {
                banners?.surfaceError("profile", error)
                return
            }
            banners?.surfaceSuccess("profile", "Server profile saved")
            if state.pendingDraft?.id == saved.id {
                state.pendingDraft = nil
            }
            state.select(saved.id, in: directory)
            // Pop back to the list after saving so the user sees the freshly
            // persisted profile in the "Configured" section.
            path.removeAll()
        }
    }
}

private struct PhoneProfileDetail: View {
    @Binding var draft: ServerProfile
    /// Typed password, lifted into `ProfileEditorState` (pre-filled from the
    /// Keychain on selection). Bound here so it never leaks into the profile.
    @Binding var passwordInput: String
    let isPending: Bool
    /// The full saveability check, computed by the parent against the lifted
    /// password state.
    let canSave: Bool
    let onSave: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        // Form is the scroll container — wrapping it in a ScrollView+VStack
        // collapses the Form to zero height on iOS.
        Form {
            if isPending {
                Section {
                    Label("This server hasn't been saved yet. Save to keep it.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            ProfileFormSections(draft: $draft, passwordInput: $passwordInput)
            if isPending {
                Section {
                    Button("Discard", role: .destructive, action: onDiscard)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save", action: onSave)
                    .disabled(!canSave)
                    .fontWeight(.semibold)
                    .help("Save the server profile")
            }
        }
    }
}

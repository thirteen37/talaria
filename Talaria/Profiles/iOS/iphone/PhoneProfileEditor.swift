import HermesKit
import SwiftUI

/// Compact iPhone profile editor: a `NavigationStack` list that pushes a
/// single-column detail form. Uses explicit push navigation because a
/// selection-driven `NavigationSplitView` push doesn't fire reliably in a
/// compact-width sheet. Password + Keychain auth via the shared form sections.
struct PhoneProfileEditor: View {
    @Environment(ProfileDirectory.self) private var directory
    @Environment(SidebarLayout.self) private var sidebarLayout
    @State private var state = ProfileEditorState()
    /// Drives the NavigationStack so `addNew()` can push the detail view.
    @State private var path: [UUID] = []
    /// Presents the global Browse-sidebar customizer (reorder / hide pages).
    @State private var showingCustomize = false
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
        .sheet(isPresented: $showingCustomize) {
            SidebarCustomizeView()
                .environment(sidebarLayout)
        }
        .task { await reload() }
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
            Section {
                Button {
                    showingCustomize = true
                } label: {
                    Label("Customize Sidebar", systemImage: "sidebar.left")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
                    isPending: state.pendingDraft?.id == id,
                    canSave: state.baseCanSave(draft, in: directory),
                    onSave: { password, changed in save(password: password, passwordChanged: changed) },
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

    private func save(password: String = "", passwordChanged: Bool = false) {
        guard var draft = state.draft,
              ProfileEditorState.isSaveable(
                draft,
                hasPasswordInput: !password.isEmpty,
                passwordChanged: passwordChanged,
                baseCanSave: state.baseCanSave(draft, in: directory)
              ) else { return }
        if draft.authMethod == .password {
            if passwordChanged, !password.isEmpty {
                let reference = draft.passwordKeychainReference ?? UUID().uuidString
                do {
                    try PasswordKeychain.set(reference: reference, password: password)
                    draft.passwordKeychainReference = reference
                } catch {
                    directory.lastError = "Couldn't save password to Keychain: \(error.localizedDescription)"
                    return
                }
            }
        } else if let reference = draft.passwordKeychainReference {
            try? PasswordKeychain.delete(reference: reference)
            draft.passwordKeychainReference = nil
        }
        let saved = draft
        Task {
            await directory.upsert(saved)
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
    let isPending: Bool
    let canSave: Bool
    let onSave: (_ password: String, _ passwordChanged: Bool) -> Void
    let onDiscard: () -> Void

    @State private var passwordInput: String = ""
    @State private var loadedPassword: String = ""

    private var passwordChanged: Bool { passwordInput != loadedPassword }

    private var canSaveNow: Bool {
        ProfileEditorState.isSaveable(
            draft,
            hasPasswordInput: !passwordInput.isEmpty,
            passwordChanged: passwordChanged,
            baseCanSave: canSave
        )
    }

    private func loadStoredPassword() {
        guard draft.authMethod == .password, passwordInput.isEmpty,
              let reference = draft.passwordKeychainReference,
              let stored = PasswordKeychain.get(reference: reference) else { return }
        passwordInput = stored
        loadedPassword = stored
    }

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
        .onAppear(perform: loadStoredPassword)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { onSave(passwordInput, passwordChanged) }
                    .disabled(!canSaveNow)
                    .fontWeight(.semibold)
                    .help("Save the server profile")
            }
        }
    }
}

import HermesKit
import SwiftUI

/// Two-pane (sidebar + detail) profile editor shared by macOS and iPad. macOS
/// hosts it in the `Settings` scene; iPad presents it as a sheet from the
/// desktop window's gear affordance. Platform differences (auth methods, the
/// `Local` kind, identity picker, probe transport) flow through the seam layer
/// — no `#if`, no `Idiom`.
struct DesktopProfileEditor: View {
    @Environment(ProfileDirectory.self) private var directory
    @State private var state = ProfileEditorState()
    /// Drives the trust-on-first-use prompt when a probe meets an unknown host
    /// key (iPad NIO path). Unused on macOS, where the system-ssh probe defers
    /// to `~/.ssh/known_hosts`.
    @State private var hostKeyCoordinator = HostKeyConfirmationCoordinator()
    /// Optional dismiss callback used by the iPad Settings sheet. macOS's
    /// `Settings` scene leaves it nil — the system Close button handles it.
    var onDismiss: (() -> Void)? = nil

    /// A navigation away from the current draft, stashed while the unsaved-edits
    /// confirmation is up. Every exit (sidebar select, add, duplicate, Done)
    /// routes through `attemptNavigation` so a dirty draft can't be abandoned
    /// silently.
    enum PendingAction {
        case select(UUID?)
        case addNew
        case duplicate
        case dismiss
    }
    @State private var pendingAction: PendingAction?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 240)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await reload() }
        .alert(
            "Trust this server?",
            isPresented: Binding(
                get: { hostKeyCoordinator.pending != nil },
                set: { _ in }
            ),
            presenting: hostKeyCoordinator.pending
        ) { _ in
            Button("Trust") { hostKeyCoordinator.resolve(true) }
            Button("Cancel", role: .cancel) { hostKeyCoordinator.resolve(false) }
        } message: { request in
            Text(
                "First connection to \(request.host):\(request.port).\n\n"
                + "Key fingerprint:\n\(request.fingerprint)\n\n"
                + "Trust and remember this server? Only do this if the fingerprint matches your server."
            )
        }
        .toolbar {
            if onDismiss != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { attemptNavigation(.dismiss) }
                        .help("Close")
                }
            }
        }
        // iPad swipe-to-dismiss would bypass the navigation guard, so block it
        // while there are unsaved edits — the only way out is Done, which is
        // guarded. No-op in the macOS Settings scene (not a sheet). The macOS
        // Settings-window close (red dot / ⌘W) is not interceptable in SwiftUI;
        // the in-editor switch guard still protects the common case.
        .interactiveDismissDisabled(state.isDirty(in: directory))
        .confirmationDialog(
            "Unsaved changes",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingAction
        ) { action in
            if canSaveCurrentDraft {
                Button("Save") {
                    save(then: action)
                    pendingAction = nil
                }
            }
            Button("Discard", role: .destructive) {
                discardEditsIfPending()
                perform(action)
                pendingAction = nil
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: { _ in
            Text(canSaveCurrentDraft
                ? "You have unsaved changes to this server."
                : "You have unsaved changes. This draft must be probed before it can be saved.")
        }
    }

    private func reload() async {
        await directory.reload()
        state.resetIfMissing(in: directory)
        if state.selection == nil, let first = directory.profiles.first {
            state.select(first.id, in: directory)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { state.selection },
                set: { attemptNavigation(.select($0)) }
            )) {
                if let pending = state.pendingDraft {
                    Section("Unsaved") {
                        row(for: pending, isDraft: true)
                            .tag(pending.id)
                    }
                }
                Section("Configured") {
                    ForEach(directory.profiles) { profile in
                        row(for: profile, isDraft: false)
                            .tag(profile.id)
                    }
                }
            }

            Divider()
            HStack(spacing: 4) {
                Button {
                    attemptNavigation(.addNew)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add server")
                .help("Add a server")
                Button {
                    attemptNavigation(.duplicate)
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .disabled(!canDuplicate)
                .accessibilityLabel("Duplicate server")
                .help("Duplicate the selected server")
                Button {
                    delete()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(state.selection == nil)
                .accessibilityLabel("Delete server")
                .help("Delete the selected server")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private var canDuplicate: Bool {
        guard let id = state.selection else { return false }
        return id != state.pendingDraft?.id && directory.profile(id: id) != nil
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

    @ViewBuilder
    private var detail: some View {
        if let draft = state.draft {
            DesktopProfileDetail(
                draft: draftBinding(for: draft.id),
                passwordInput: $state.passwordInput,
                probeState: state.probeStates[draft.id] ?? .idle,
                canSave: canSaveCurrentDraft,
                isPending: state.pendingDraft?.id == draft.id,
                onProbe: { runProbe() },
                onSave: { save() },
                onDiscard: { discardPending() }
            )
            .id(draft.id)
        } else {
            ContentUnavailableView(
                "Select a server",
                systemImage: "server.rack",
                description: Text("Add a new server or pick one on the left.")
            )
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

    private func addNew() {
        let profile = ServerProfile(name: "New Server", kind: .ssh)
        state.pendingDraft = profile
        // Snapshot the fresh draft so an untouched new server doesn't trip the
        // dirty check when the user navigates away without editing.
        state.pendingBaseline = profile
        state.select(profile.id, in: directory)
    }

    /// Whether the current draft can be saved right now — the single source of
    /// truth shared by the pinned Save button and the confirmation dialog.
    private var canSaveCurrentDraft: Bool {
        guard let draft = state.draft else { return false }
        return ProfileEditorState.isSaveable(
            draft,
            hasPasswordInput: !state.passwordInput.isEmpty,
            passwordChanged: state.passwordChanged,
            baseCanSave: state.baseCanSave(draft, in: directory)
        )
    }

    /// Routes a navigation away from the current draft through the dirty check:
    /// performs it immediately when clean, otherwise raises the confirmation.
    private func attemptNavigation(_ action: PendingAction) {
        if state.isDirty(in: directory) {
            pendingAction = action
        } else {
            perform(action)
        }
    }

    private func perform(_ action: PendingAction) {
        switch action {
        case let .select(id): state.select(id, in: directory)
        case .addNew: addNew()
        case .duplicate: duplicate()
        case .dismiss: onDismiss?()
        }
    }

    /// Drops in-progress edits to an unsaved (pending) draft by reverting it to
    /// its creation snapshot, so re-selecting it later doesn't resurface the
    /// discarded edits. Persisted profiles need no reset — `perform`'s
    /// re-`select` reloads them from disk.
    private func discardEditsIfPending() {
        guard let draft = state.draft,
              state.pendingDraft?.id == draft.id,
              let baseline = state.pendingBaseline else { return }
        state.pendingDraft = baseline
        state.draft = baseline
    }

    private func discardPending() {
        guard let pending = state.pendingDraft else { return }
        state.pendingDraft = nil
        state.probeStates.removeValue(forKey: pending.id)
        state.validatedThisSession.remove(pending.id)
        state.select(directory.profiles.first?.id, in: directory)
    }

    private func duplicate() {
        guard let id = state.selection, canDuplicate else { return }
        Task {
            if let copy = await directory.duplicate(id: id) {
                state.select(copy.id, in: directory)
            }
        }
    }

    private func delete() {
        guard let id = state.selection else { return }
        if id == state.pendingDraft?.id {
            discardPending()
            return
        }
        Task {
            await directory.delete(id: id)
            state.probeStates.removeValue(forKey: id)
            state.validatedThisSession.remove(id)
            state.select(directory.profiles.first?.id, in: directory)
        }
    }

    /// Persists the current draft. The password now lives in `state`, so it's
    /// read from there rather than passed in. `then` lets the confirmation
    /// dialog chain a navigation (select another profile / dismiss) *after* the
    /// save lands, instead of the default "re-select the saved profile."
    private func save(then action: PendingAction? = nil) {
        guard var draft = state.draft,
              ProfileEditorState.isSaveable(
                draft,
                hasPasswordInput: !state.passwordInput.isEmpty,
                passwordChanged: state.passwordChanged,
                baseCanSave: state.baseCanSave(draft, in: directory)
              ) else { return }
        // PasswordKeychain is cross-platform (macOS no-ops); `authMethod` is
        // never `.password` on macOS (no password auth), so this whole block is
        // inert there and needs no `#if`.
        if draft.authMethod == .password {
            // Persist the typed password into the Keychain only when it
            // actually changed. The draft holds just a reference UUID; the
            // password itself stays in the OS Keychain.
            if state.passwordChanged, !state.passwordInput.isEmpty {
                let reference = draft.passwordKeychainReference ?? UUID().uuidString
                do {
                    try PasswordKeychain.set(reference: reference, password: state.passwordInput)
                    draft.passwordKeychainReference = reference
                } catch {
                    directory.lastError = "Couldn't save password to Keychain: \(error.localizedDescription)"
                    return
                }
            }
        } else if let reference = draft.passwordKeychainReference {
            // Switched away from password auth — purge the stored secret and
            // drop the dangling reference so it isn't orphaned in the Keychain.
            try? PasswordKeychain.delete(reference: reference)
            draft.passwordKeychainReference = nil
        }
        let saved = draft
        Task {
            await directory.upsert(saved)
            // Clear pending status once the draft is on disk.
            if state.pendingDraft?.id == saved.id {
                state.pendingDraft = nil
            }
            if let action {
                perform(action)
            } else {
                // Re-select reloads the (now-persisted) password, resetting the
                // dirty check.
                state.select(saved.id, in: directory)
            }
        }
    }

    private func runProbe() {
        guard let probed = state.draft else { return }
        let id = probed.id
        state.probeStates[id] = .running
        let confirmer: HostKeyConfirmer = { host, port, fingerprint in
            await hostKeyCoordinator.confirm(host: host, port: port, fingerprint: fingerprint)
        }
        // Thread the in-progress password so a brand-new/unsaved password
        // profile probes with the typed value (empty on macOS — no password
        // auth — so this is inert there).
        let password = state.passwordInput
        Task {
            do {
                let result = try await ProfileProber.probe(profile: probed, password: password, confirmer: confirmer)
                // Bind to the captured probed value: if the user edited the
                // draft while the probe was in flight, the result no longer
                // describes the live configuration — drop it instead of
                // marking the new config validated.
                guard state.draft == probed else {
                    state.probeStates[id] = .idle
                    return
                }
                state.probeStates[id] = .success(result)
                // Stamp the version onto the draft before recording the
                // validation. Going through updateDraft would clear the
                // validation flag (mutation guard) so we set the field
                // directly; the only diff vs the probed value is the
                // discovered version itself.
                if var current = state.draft, current.id == id {
                    current.version = result.version
                    state.draft = current
                    if state.pendingDraft?.id == current.id {
                        state.pendingDraft = current
                    }
                }
                state.validatedThisSession.insert(id)
            } catch {
                guard state.draft == probed else {
                    state.probeStates[id] = .idle
                    return
                }
                state.probeStates[id] = .failure(humanReadable(error))
            }
        }
    }

    private func humanReadable(_ error: Error) -> String {
        if let probe = error as? HermesProbeError {
            switch probe {
            case let .binaryNotFound(message): return "Hermes binary not found: \(message)"
            case let .versionUnparseable(raw): return "Couldn't parse version: \(raw)"
            case let .probeFailed(message): return message
            case let .transportFailed(transport): return transport.message
            }
        }
        if let transport = error as? SSHTransportError {
            return transport.message
        }
        return error.localizedDescription
    }
}

/// Detail pane: form sections + capability probe + action buttons. Vertical
/// scroll wraps the grouped form so the probe panel and buttons stay reachable.
private struct DesktopProfileDetail: View {
    @Binding var draft: ServerProfile
    /// The typed password, lifted into `ProfileEditorState` so the parent can
    /// compute "dirty" where navigation happens. Empty/unused on macOS.
    @Binding var passwordInput: String
    let probeState: ProfileEditorState.ProbeState
    /// Whether the draft can be saved right now (the full `isSaveable` result,
    /// computed by the parent against the lifted password state).
    let canSave: Bool
    let isPending: Bool
    let onProbe: () -> Void
    let onSave: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        // A single `Form` is the scroll container on every platform. Nesting a
        // `Form` inside a `ScrollView`+`VStack` (the natural macOS layout)
        // collapses it to zero height on iOS/iPadOS, which hid every field on
        // iPad — only the banner, capabilities row, and buttons showed. Putting
        // the capabilities in its own section keeps it reachable on both
        // platforms without that nesting; the actions live in a pinned bottom
        // bar (`safeAreaInset`) so Save can't scroll out of reach.
        Form {
            if isPending {
                Section {
                    Label("This server hasn't been saved yet. Probe and Save to keep it.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            ProfileFormSections(draft: $draft, passwordInput: $passwordInput)
            Section("Capabilities") {
                probeContent
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            actionBar
        }
    }

    /// Probe / Save / Discard pinned below the scrolling form so they stay
    /// visible regardless of scroll position.
    private var actionBar: some View {
        HStack {
            Button("Probe", action: onProbe)
            Button("Save", action: onSave)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            if isPending {
                Button("Discard", role: .destructive, action: onDiscard)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var probeContent: some View {
        switch probeState {
        case .idle:
            Text("Run a probe to record the Hermes version and confirm SSH connectivity.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Probing…")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case let .success(result):
            ProbeCapabilityView(result: result)
        case let .failure(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

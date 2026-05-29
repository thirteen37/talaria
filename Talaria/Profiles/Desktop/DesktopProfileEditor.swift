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
            if let onDismiss {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
            }
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
                set: { state.select($0, in: directory) }
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
                    addNew()
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    duplicate()
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .disabled(!canDuplicate)
                Button {
                    delete()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(state.selection == nil)
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
                probeState: state.probeStates[draft.id] ?? .idle,
                canSave: state.baseCanSave(draft, in: directory),
                isPending: state.pendingDraft?.id == draft.id,
                onProbe: { runProbe() },
                onSave: { password, changed in save(password: password, passwordChanged: changed) },
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
        state.select(profile.id, in: directory)
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

    private func save(password: String = "", passwordChanged: Bool = false) {
        guard var draft = state.draft,
              ProfileEditorState.isSaveable(
                draft,
                hasPasswordInput: !password.isEmpty,
                passwordChanged: passwordChanged,
                baseCanSave: state.baseCanSave(draft, in: directory)
              ) else { return }
        // PasswordKeychain is cross-platform (macOS no-ops); `authMethod` is
        // never `.password` on macOS (no password auth), so this whole block is
        // inert there and needs no `#if`.
        if draft.authMethod == .password {
            // Persist the typed password into the Keychain only when it
            // actually changed. The draft holds just a reference UUID; the
            // password itself stays in the OS Keychain.
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
            state.select(saved.id, in: directory)
        }
    }

    private func runProbe() {
        guard let probed = state.draft else { return }
        let id = probed.id
        state.probeStates[id] = .running
        let confirmer: HostKeyConfirmer = { host, port, fingerprint in
            await hostKeyCoordinator.confirm(host: host, port: port, fingerprint: fingerprint)
        }
        Task {
            do {
                let result = try await ProfileProber.probe(profile: probed, confirmer: confirmer)
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
    let probeState: ProfileEditorState.ProbeState
    let canSave: Bool
    let isPending: Bool
    let onProbe: () -> Void
    /// Save callback receives the typed password (empty on macOS) and whether
    /// it differs from the pre-filled stored value.
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

    /// Loads any saved password into the field so it renders masked, rather
    /// than appearing empty when a password is in fact stored. No-op on macOS
    /// (no password auth → `PasswordKeychain.get` returns nil there anyway).
    private func loadStoredPassword() {
        guard draft.authMethod == .password, passwordInput.isEmpty,
              let reference = draft.passwordKeychainReference,
              let stored = PasswordKeychain.get(reference: reference) else { return }
        passwordInput = stored
        loadedPassword = stored
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isPending {
                    Label("This server hasn't been saved yet. Probe and Save to keep it.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.top)
                }
                Form {
                    ProfileFormSections(draft: $draft, passwordInput: $passwordInput)
                }
                .formStyle(.grouped)

                probeSection
                    .padding(.horizontal)

                HStack {
                    if isPending {
                        Button("Discard", role: .destructive, action: onDiscard)
                    }
                    Spacer()
                    Button("Probe", action: onProbe)
                    Button("Save") { onSave(passwordInput, passwordChanged) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSaveNow)
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .onAppear(perform: loadStoredPassword)
    }

    @ViewBuilder
    private var probeSection: some View {
        GroupBox("Capabilities") {
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
}

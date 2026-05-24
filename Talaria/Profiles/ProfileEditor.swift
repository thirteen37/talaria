import AppKit
import HermesKit
import SwiftUI

@MainActor
@Observable
final class ProfileEditorState {
    enum ProbeState: Equatable {
        case idle
        case running
        case success(HermesProbeResult)
        case failure(String)
    }

    /// Selection identifies either a persisted profile (in `directory.profiles`)
    /// or the in-memory new draft (`pendingDraft.id`). Pending drafts are NOT
    /// written to disk until the user explicitly hits Save.
    var selection: UUID?
    var draft: ServerProfile?
    var pendingDraft: ServerProfile?
    var probeStates: [UUID: ProbeState] = [:]
    /// Tracks profiles where the user ran a successful probe in this session.
    /// Persisted profiles that already have a recorded `.version` are also
    /// considered "validated" via the `canSave` check.
    var validatedThisSession: Set<UUID> = []

    func select(_ id: UUID?, in directory: ProfileDirectory) {
        selection = id
        guard let id else {
            draft = nil
            return
        }
        if id == pendingDraft?.id {
            draft = pendingDraft
        } else {
            draft = directory.profile(id: id)
        }
    }

    func updateDraft(_ profile: ServerProfile) {
        // Any user-driven edit invalidates the prior probe — the recorded
        // version came from a configuration that may no longer match.
        if let existing = draft, existing != profile {
            validatedThisSession.remove(profile.id)
            probeStates[profile.id] = .idle
        }
        draft = profile
        if pendingDraft?.id == profile.id {
            pendingDraft = profile
        }
    }

    func resetIfMissing(in directory: ProfileDirectory) {
        if let selection,
           directory.profile(id: selection) == nil,
           selection != pendingDraft?.id {
            self.selection = nil
            draft = nil
        }
    }
}

struct ProfileEditor: View {
    @Environment(ProfileDirectory.self) private var directory
    @State private var state = ProfileEditorState()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 240)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            await directory.reload()
            state.resetIfMissing(in: directory)
            if state.selection == nil, let first = directory.profiles.first {
                state.select(first.id, in: directory)
            }
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
            ProfileDetailView(
                draft: draftBinding(for: draft.id),
                probeState: state.probeStates[draft.id] ?? .idle,
                canSave: canSave(draft),
                isPending: state.pendingDraft?.id == draft.id,
                onProbe: { runProbe() },
                onSave: { save() },
                onDiscard: { discardPending() },
                onPickIdentity: { pickIdentity() }
            )
            .id(draft.id)
        } else {
            ContentUnavailableView(
                "Select a profile",
                systemImage: "server.rack",
                description: Text("Add a new server profile or pick one on the left.")
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

    private func canSave(_ draft: ServerProfile) -> Bool {
        // Pending new drafts require at least one successful probe before they
        // can be persisted — same gating as plan-of-record.
        if state.pendingDraft?.id == draft.id {
            return state.validatedThisSession.contains(draft.id)
        }
        // For persisted profiles, allow Save when the draft diverges from
        // disk. A previously validated `.version` keeps the profile saveable
        // across sessions; otherwise the user must Probe before Save.
        guard let existing = directory.profile(id: draft.id) else { return false }
        if existing == draft { return false }
        return state.validatedThisSession.contains(draft.id) || existing.version != nil
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

    private func save() {
        guard let draft = state.draft, canSave(draft) else { return }
        Task {
            await directory.upsert(draft)
            // Clear pending status once the draft is on disk.
            if state.pendingDraft?.id == draft.id {
                state.pendingDraft = nil
            }
            state.select(draft.id, in: directory)
        }
    }

    private func runProbe() {
        guard let probed = state.draft else { return }
        let id = probed.id
        state.probeStates[id] = .running
        Task {
            do {
                let result = try await HermesProbe.probe(profile: probed)
                // Bind to the captured probed value: if the user edited the
                // draft while the probe was in flight, the result no longer
                // describes the live configuration — drop it instead of
                // marking the new config validated. Reset the probe badge
                // to .idle so re-selecting this profile later doesn't show
                // a stuck "Probing…" indicator.
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
                // Same race guard for failure: only surface the error if the
                // user hasn't moved on to a different configuration. Reset
                // the badge either way so it doesn't get stuck.
                guard state.draft == probed else {
                    state.probeStates[id] = .idle
                    return
                }
                state.probeStates[id] = .failure(humanReadable(error))
            }
        }
    }

    private func pickIdentity() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if var current = state.draft {
            current.identityFile = url.path
            state.updateDraft(current)
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

private struct ProfileDetailView: View {
    @Binding var draft: ServerProfile
    let probeState: ProfileEditorState.ProbeState
    let canSave: Bool
    let isPending: Bool
    let onProbe: () -> Void
    let onSave: () -> Void
    let onDiscard: () -> Void
    let onPickIdentity: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isPending {
                    Label("This profile hasn't been saved yet. Probe and Save to keep it.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.top)
                }
                Form {
                    Section("Identity") {
                        TextField("Name", text: $draft.name)
                        Picker("Kind", selection: $draft.kind) {
                            Text("Local").tag(ServerProfile.Kind.local)
                            Text("SSH").tag(ServerProfile.Kind.ssh)
                        }
                    }

                    if draft.kind == .ssh {
                        Section("SSH") {
                            TextField("Host", text: bindingString(\.host))
                            TextField("User (optional)", text: bindingString(\.user))
                            TextField("Port (optional)", text: bindingInt(\.port))
                            HStack {
                                TextField("Identity file (optional)", text: bindingString(\.identityFile))
                                Button("Choose…", action: onPickIdentity)
                            }
                        }
                    }

                    Section("Hermes") {
                        TextField("Hermes binary", text: $draft.hermesPath)
                        TextField("HERMES_HOME (optional)", text: bindingString(\.hermesHome))
                    }

                    if draft.kind == .ssh {
                        Section {
                            Picker("Remote shell", selection: $draft.remoteShellMode) {
                                ForEach(RemoteShellMode.allCases, id: \.self) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            if draft.remoteShellMode == .custom {
                                TextField(
                                    "Custom prefix (e.g. \"mise exec --\")",
                                    text: bindingString(\.remoteShellPrefix)
                                )
                                .font(.system(.body, design: .monospaced))
                            }
                        } header: {
                            Text("Remote shell")
                        } footer: {
                            Text(
                                "Ssh's non-interactive command path doesn't source ~/.zshrc or ~/.bashrc, so PATH-based hermes lookups fail. Login-shell wrappers source profile files where PATH is usually set. Pick Direct if hermes is at an absolute path."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
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
                    Button("Save", action: onSave)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
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

    private func bindingString(_ keyPath: WritableKeyPath<ServerProfile, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { newValue in
                draft[keyPath: keyPath] = newValue.isEmpty ? nil : newValue
            }
        )
    }

    private func bindingInt(_ keyPath: WritableKeyPath<ServerProfile, Int?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath].map(String.init) ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                draft[keyPath: keyPath] = trimmed.isEmpty ? nil : Int(trimmed)
            }
        )
    }
}

private struct ProbeCapabilityView: View {
    let result: HermesProbeResult

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            row("Binary", value: result.binaryPath)
            row("Version", value: result.versionRaw)
            row("ACP supported", value: result.acpSupported ? "Yes" : "No")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}

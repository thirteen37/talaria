import HermesKit
import SwiftUI

/// The profile-editor form sections, shared by the desktop (macOS + iPad) and
/// iPhone editors. Platform differences flow through the seam layer rather
/// than `#if`:
/// - the Kind picker offers `Local` only where `Platform.supportsLocalProfile`,
/// - the SSH auth picker (password + Keychain) appears only where
///   `Platform.supportsPasswordAuth`,
/// - "Choose…" routes through `.identityFilePicker` (NSOpenPanel / fileImporter).
struct ProfileFormSections: View {
    @Binding var draft: ServerProfile
    /// iOS-only typed password (empty / unused on macOS, which has no password
    /// auth). Lives in the parent so it never leaks into the persisted profile.
    @Binding var passwordInput: String

    @State private var showingIdentityPicker = false

    var body: some View {
        Group {
            Section("Identity") {
                TextField("Name", text: $draft.name)
                Picker("Kind", selection: $draft.kind) {
                    if Platform.supportsLocalProfile {
                        Text("Local").tag(ServerProfile.Kind.local)
                    }
                    Text("SSH").tag(ServerProfile.Kind.ssh)
                }
            }

            if draft.kind == .ssh {
                Section("SSH") {
                    TextField("Host", text: $draft.string(\.host))
                    TextField("User (optional)", text: $draft.string(\.user))
                    TextField("Port (optional)", text: $draft.int(\.port))
                    if Platform.supportsPasswordAuth {
                        Picker("Auth", selection: $draft.authMethod) {
                            Text("Identity file").tag(SSHAuthMethod.identityFile)
                            Text("Password").tag(SSHAuthMethod.password)
                        }
                        if draft.authMethod == .password {
                            SecureField("Password", text: $passwordInput)
                        } else {
                            identityRow
                        }
                    } else {
                        identityRow
                    }
                }
            }

            Section("Hermes") {
                TextField("Hermes binary", text: $draft.hermesPath)
                TextField("HERMES_HOME (optional)", text: $draft.string(\.hermesHome))
                TextField("Dashboard port (optional)", text: $draft.int(\.dashboardPort))
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
                            text: $draft.string(\.remoteShellPrefix)
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
    }

    private var identityRow: some View {
        HStack {
            TextField("Identity file (optional)", text: $draft.string(\.identityFile))
            Button("Choose…") { showingIdentityPicker = true }
        }
        .identityFilePicker(isPresented: $showingIdentityPicker) { path in
            draft.identityFile = path
        }
    }
}

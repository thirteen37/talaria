import SwiftUI

/// Settings screen for OS-level chat notifications: a master toggle plus two
/// conditional sub-toggles (agent-finished, tool-approval), backed by the
/// app-wide ``NotificationSettings``. Flipping the master on triggers the OS
/// authorization request. Shared across the macOS Settings scene and the
/// iPad/iPhone settings sheets, mirroring ``SidebarCustomizeView``'s structure.
struct NotificationsSettingsView: View {
    @Environment(NotificationSettings.self) private var settings
    /// Provided only when presented as a dismissable sheet (iPad / iPhone). The
    /// macOS Settings tab leaves it nil — the window's close handles dismissal.
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        @Bindable var settings = settings
        let form = Form {
            Section {
                Toggle("Enable notifications", isOn: Binding(
                    get: { settings.notificationsEnabled },
                    set: { isOn in
                        settings.notificationsEnabled = isOn
                        // Ask the OS for permission the first time the user opts
                        // in — no point prompting before then.
                        if isOn {
                            ChatNotifier.shared.requestAuthorizationIfNeeded()
                        }
                    }
                ))
                .help("Show notifications for chat events")
            } footer: {
                Text("Notifications appear only when you're not actively viewing the chat.")
            }

            if settings.notificationsEnabled {
                Section {
                    Toggle("Agent finished responding", isOn: $settings.notifyAgentFinished)
                        .help("Notify when a turn you started finishes")
                    Toggle("Tool approval needed", isOn: $settings.notifyToolApproval)
                        .help("Notify when a tool is waiting for your approval")
                } header: {
                    Text("Notify me when")
                }
            }

            // Independent of the master toggle above: a user may want update
            // notices without chat notices (or vice versa).
            Section {
                Toggle("Check for Hermes updates in the background", isOn: Binding(
                    get: { settings.checkForUpdatesInBackground },
                    set: { isOn in
                        settings.checkForUpdatesInBackground = isOn
                        // The surfacing is an OS notification, so ask for
                        // permission the first time the user opts in.
                        if isOn {
                            ChatNotifier.shared.requestAuthorizationIfNeeded()
                        }
                    }
                ))
                .help("Periodically run `hermes update --check` and notify you when an update is available")

                if settings.checkForUpdatesInBackground {
                    Picker("Check every", selection: $settings.updateCheckInterval) {
                        ForEach(UpdateCheckInterval.allCases, id: \.self) { interval in
                            Text(interval.label).tag(interval)
                        }
                    }
                    .help("How often to check for Hermes updates")
                }
            } header: {
                Text("Hermes updates")
            }
        }

        #if os(iOS)
        return NavigationStack {
            form
                .navigationBarTitleDisplayMode(.inline)
                .navigationTitle("Notifications")
                .toolbar {
                    if let onDismiss {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", action: onDismiss)
                                .help("Close")
                        }
                    }
                }
        }
        #else
        return form
        #endif
    }
}

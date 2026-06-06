import SwiftUI

/// Developer/experimental settings. Currently the live-chat backend opt-in:
/// drive chat over the dashboard `/api/ws` gateway instead of the ACP
/// subprocess. Backed by the same `UserDefaults` key the harness reads
/// (`ServerWindowHarness.useGatewayChatDefaultsKey`); read when a chat window /
/// session is created, so changes apply to newly opened windows.
struct DeveloperSettingsView: View {
    /// Provided only when presented as a dismissable sheet (iPad / iPhone). The
    /// macOS Settings tab leaves it nil — the window's close handles dismissal.
    var onDismiss: (() -> Void)? = nil

    @AppStorage(ServerWindowHarness.useGatewayChatDefaultsKey)
    private var useGatewayChat = false

    var body: some View {
        let form = Form {
            Section {
                Toggle("Use the /api/ws chat gateway", isOn: $useGatewayChat)
                    .help("Run live chat over the dashboard WebSocket gateway instead of the ACP subprocess")
            } header: {
                Text("Live chat backend")
            } footer: {
                Text("""
                Experimental. Runs live chat over the dashboard /api/ws gateway (the path \
                Hermes Desktop uses) instead of spawning a separate `hermes acp` process. \
                Applies to chat windows opened after this change, and only when the connected \
                Hermes supports the gateway — it falls back to ACP automatically otherwise. \
                The chat status bar shows a "WS" or "ACP" badge for the active session.
                """)
            }
        }

        #if os(iOS)
        return NavigationStack {
            form
                .navigationBarTitleDisplayMode(.inline)
                .navigationTitle("Developer")
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

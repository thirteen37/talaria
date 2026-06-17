import HermesKit
import SwiftUI

/// Modal "Browse" sheet for the compact iPhone window: a `NavigationStack`
/// listing every manage surface (Skills … Notifications) plus a Settings row,
/// drilling into each via the shared `BrowseDetailView`. iPhone keeps chat as
/// its single root stack, so the full desktop feature set lives here behind one
/// toolbar button instead of a sidebar.
struct PhoneBrowseSheet: View {
    let harness: ServerWindowHarness
    /// Hermes profiles on the server, surfaced by the window — fed to the
    /// Configuration editor's compare dropdown.
    var hermesProfiles: [HermesProfileInfo] = []
    /// The window's active Hermes profile (`-p <name>`), highlighted in the
    /// Profiles management table.
    var activeHermesProfile: String = HermesProfiles.defaultProfileName
    /// Invoked after a Profiles mutation so the window refreshes its switcher
    /// and reconciles the active profile if it was renamed/deleted.
    var onProfilesChanged: () -> Void = {}
    /// Initial nested stack to seed: a deep link (e.g. the bell → Notifications)
    /// becomes `[destination]`; a cold-relaunch restore passes the full saved
    /// sub-path. Empty lands on the Browse root list.
    var initialPath: [BrowseDestination] = []
    /// Reports the nested stack each time it changes so the host window can
    /// persist it for cold-relaunch restoration.
    var onPathChange: ([BrowseDestination]) -> Void = { _ in }
    /// Settings is iPhone-only and not a `BrowseDestination`. Tapping its row
    /// dismisses this sheet and hands off to the window's body-level Settings
    /// sheet — `ProfileEditorRoot` is built as its own `NavigationStack`, so it
    /// doesn't compose as a pushed view here.
    var onOpenSettings: () -> Void
    var onDismiss: () -> Void

    @Environment(SidebarLayout.self) private var sidebarLayout
    /// Window navigator: re-injected by the host window so `EntityLink` taps
    /// *inside* a browse page re-navigate this sheet's stack to the target page.
    @Environment(WindowNavigator.self) private var navigator: WindowNavigator?
    @State private var path: [BrowseDestination] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(sidebarLayout.visibleManageDestinations(), id: \.self) { destination in
                        NavigationLink(value: destination) {
                            Label(destination.title, systemImage: destination.systemImage)
                        }
                    }
                }
                Section {
                    Button {
                        onOpenSettings()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text(AppBuildInfo.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .textSelection(.enabled)
                        .accessibilityLabel("App build: \(AppBuildInfo.summary)")
                }
            }
            .navigationTitle("Browse")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: BrowseDestination.self) { destination in
                BrowseDetailView(
                    harness: harness,
                    destination: destination,
                    hermesProfiles: hermesProfiles,
                    activeHermesProfile: activeHermesProfile,
                    onProfilesChanged: onProfilesChanged
                )
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                        .help("Close")
                }
            }
        }
        .onAppear {
            if path.isEmpty, !initialPath.isEmpty {
                path = initialPath
            }
        }
        // Surface every nested-stack change so the host window can persist the
        // depth for cold-relaunch restoration.
        .onChange(of: path) { _, newPath in
            onPathChange(newPath)
        }
        // An EntityLink tapped inside a browse page (sheet already open) re-points
        // the stack at the target page; the page itself consumes the focus.
        .onChange(of: navigator?.pendingFocus) { _, newValue in
            guard let ref = newValue ?? nil, ref.sessionId == nil else { return }
            if path.last != ref.destination {
                path = [ref.destination]
            }
        }
    }
}

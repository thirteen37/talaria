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
    /// Optional deep link (e.g. the bell → Notifications): seeds the stack so
    /// the sheet opens directly on that surface.
    var initial: BrowseDestination?
    /// Settings is iPhone-only and not a `BrowseDestination`. Tapping its row
    /// dismisses this sheet and hands off to the window's body-level Settings
    /// sheet — `ProfileEditorRoot` is built as its own `NavigationStack`, so it
    /// doesn't compose as a pushed view here.
    var onOpenSettings: () -> Void
    var onDismiss: () -> Void

    @State private var path: [BrowseDestination] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(BrowseDestination.manageOrder, id: \.self) { destination in
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
                    onProfilesChanged: onProfilesChanged,
                    // Keep deep links inside this sheet's stack (e.g. a
                    // notification's "Open Doctor" pushes Doctor here).
                    onOpenDestination: { dest in path.append(dest) }
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
            if let initial, path.isEmpty {
                path = [initial]
            }
        }
    }
}

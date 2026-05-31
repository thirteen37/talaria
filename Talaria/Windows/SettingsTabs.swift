import SwiftUI

/// The app's Settings screen: a two-tab `TabView` over the server-profile
/// editor and the Browse-sidebar order customizer. Shared across the macOS
/// Settings scene, the iPad settings sheet, and the iPhone settings sheet, so
/// both surfaces live behind one consistent entry. Lives in the shared
/// `Talaria/` tree (no `macOS/`/`iOS/` seam folder), so it compiles for both
/// targets.
///
/// Each tab owns its own navigation: the profile editor brings its platform
/// chrome (iPhone push stack / iPad two-pane in a `NavigationStack` / macOS
/// two-pane) and ``SidebarCustomizeView`` wraps itself in a `NavigationStack`.
/// `onDismiss` is forwarded to both tabs so the sheet contexts (iPad / iPhone)
/// show a Done button; the macOS Settings scene leaves it nil (window close).
struct SettingsTabs: View {
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        TabView {
            profilesTab
                .tabItem { Label("Server Profiles", systemImage: "server.rack") }
            SidebarCustomizeView(onDismiss: onDismiss)
                .settingsTabFrame()
                .tabItem { Label("Sidebar Order", systemImage: "sidebar.left") }
        }
    }

    @ViewBuilder
    private var profilesTab: some View {
        #if os(iOS)
        // `ProfileEditorRoot` picks the iPhone push form or the iPad two-pane
        // editor (and supplies the iPad's `NavigationStack`).
        ProfileEditorRoot(onDismiss: onDismiss)
        #else
        // macOS hosts the two-pane editor directly in the framed Settings window.
        DesktopProfileEditor(onDismiss: onDismiss)
            .settingsTabFrame()
        #endif
    }
}

private extension View {
    /// Sizes a Settings tab's content on macOS (where the per-tab frame drives
    /// the preferences window size). No-op on iOS, where the sheet fills the
    /// screen.
    @ViewBuilder
    func settingsTabFrame() -> some View {
        #if os(macOS)
        frame(minWidth: 520, minHeight: 360)
        #else
        self
        #endif
    }
}

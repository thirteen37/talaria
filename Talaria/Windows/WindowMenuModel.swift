import HermesKit
import SwiftUI

/// Data + closures the menu-bar commands need from the **focused** desktop
/// window. `DesktopServerWindow` publishes one of these via `.focusedSceneValue`
/// each `body` eval; `WindowCommands`' menus read it through
/// `@FocusedValue(\.windowMenu)`. The frontmost window wins, matching the
/// per-window architecture — the menus stay pure consumers (no `SidebarLayout`
/// or `directory` dependency, no observation inside `Commands`).
///
/// The closures mutate the publishing window's `@State` / call its existing
/// switch methods exactly as the sidebar buttons do.
struct WindowMenuModel {
    // Navigation
    /// Sections to list, already encoding hide + reorder
    /// (`[.sessions] + sidebarLayout.visibleManageDestinations()`).
    var browseDestinations: [BrowseDestination]
    /// The section currently shown in the detail pane, or `nil` when a session
    /// tab is focused (so no View item is checked).
    var currentBrowse: BrowseDestination?
    var selectBrowse: (BrowseDestination) -> Void

    // Session
    var isOpeningSession: Bool
    var newSession: () -> Void

    // Sidebar + open-session tabs
    /// Flips the window's sidebar between shown and hidden (the View menu's
    /// Hide/Show Sidebar item; ⌃⌘S).
    var toggleSidebar: () -> Void
    /// Cycle the selected open-session tab forward / backward with wrap-around
    /// (⌃Tab / ⌃⇧Tab). No-ops when nothing is open.
    var selectNextSession: () -> Void
    var selectPreviousSession: () -> Void
    /// Closes the focused session tab (the File menu's Close Session item; ⌘W).
    var closeSession: () -> Void
    /// True when a session tab is selected, so Close Session is enabled; when
    /// false ⌘W falls through to the system Close Window.
    var canCloseSession: Bool

    // Chat actions (scoped to the focused window's active session)
    /// Copies the active chat's most recent agent response (Edit menu, ⌘⇧C).
    var copyLastResponse: () -> Void
    /// True when the active chat has an agent response to copy (drives the Copy
    /// Last Response item's enabled state).
    var canCopyLastResponse: Bool

    // Server profile
    var serverProfiles: [ServerProfile]
    var currentServerId: UUID
    var switchServer: (UUID) -> Void

    // Hermes profile
    var hermesProfiles: [HermesProfileInfo]
    var activeHermesProfile: String
    var isLoadingHermesProfiles: Bool
    var switchHermes: (String) -> Void
}

struct WindowMenuModelKey: FocusedValueKey {
    typealias Value = WindowMenuModel
}

extension FocusedValues {
    /// The focused desktop window's menu model, or `nil` when no such window is
    /// focused (menus then render a disabled fallback so structure + shortcuts
    /// stay discoverable).
    var windowMenu: WindowMenuModel? {
        get { self[WindowMenuModelKey.self] }
        set { self[WindowMenuModelKey.self] = newValue }
    }
}

import HermesKit
import SwiftUI

/// Menu-bar commands for the desktop window (macOS menu bar + iPad
/// hardware-keyboard menu): jump to a section, start a new session, switch the
/// server / Hermes profile. Every menu reads the **focused** window's
/// `WindowMenuModel` via `@FocusedValue`; with no focused window the items show
/// disabled (canonical fallback) so structure + shortcuts stay discoverable.
struct WindowCommands: Commands {
    /// Recent-servers list, shared with `ServerCommands`. Used to seed New
    /// Window's default profile and to record a server opened in a new window.
    let recents: RecentServers

    var body: some Commands {
        // Replace the WindowGroup's default "New Window ⌘N" with New Session ⌘N
        // (plus New Window ⌘⇧N, to preserve new-window access).
        CommandGroup(replacing: .newItem) { NewItemMenu(recents: recents) }
        // Add to the existing standard View menu (a bare CommandMenu("View")
        // would create a duplicate). The sidebar toggle + tab-cycle items lead;
        // the ⌘-digit section list follows.
        CommandGroup(after: .sidebar) {
            ViewExtrasMenu()
            SectionMenu()
        }
        // Edit menu: a discoverable home for the chat's ⌘⇧C copy-last-response
        // (it'd otherwise be an invisible window-wide shortcut).
        CommandGroup(after: .pasteboard) { CopyResponseMenu() }
        CommandMenu("Profiles") { ProfilesMenu(recents: recents) }
    }
}

/// Maps a section's position in the sidebar order to its ⌘-digit shortcut:
/// indices 0…8 → ⌘1…⌘9, index 9 → ⌘0, and a 11th+ section gets none.
enum SectionShortcut {
    static func keyEquivalent(forIndex index: Int) -> KeyEquivalent? {
        switch index {
        case 0..<9: return KeyEquivalent(Character("\(index + 1)"))
        case 9: return "0"
        default: return nil
        }
    }

    /// The full ⌘-modified shortcut, or `nil` past the tenth section so the
    /// item simply gets no shortcut.
    static func shortcut(forIndex index: Int) -> KeyboardShortcut? {
        keyEquivalent(forIndex: index).map { KeyboardShortcut($0, modifiers: .command) }
    }
}

/// **View menu** section list, mirroring the customized sidebar (Sessions +
/// visible manage destinations, in the user's order) with ⌘1…⌘9, ⌘0.
private struct SectionMenu: View {
    @FocusedValue(\.windowMenu) private var model

    var body: some View {
        let destinations = model?.browseDestinations ?? BrowseDestination.sidebarOrder
        Divider()
        ForEach(Array(destinations.enumerated()), id: \.element) { index, destination in
            Toggle(isOn: Binding(
                get: { model?.currentBrowse == destination },
                // Selecting re-selects the section regardless of the toggle's
                // new value (clicking the checked item keeps it selected).
                set: { _ in model?.selectBrowse(destination) }
            )) {
                Label(destination.title, systemImage: destination.systemImage)
            }
            .keyboardShortcut(SectionShortcut.shortcut(forIndex: index))
        }
        .disabled(model == nil)
    }
}

/// **File menu** new-item group: New Session ⌘N + New Window ⌘⇧N.
private struct NewItemMenu: View {
    let recents: RecentServers
    @FocusedValue(\.windowMenu) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Session") { model?.newSession() }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(model == nil || model?.isOpeningSession == true)

        Button("New Window") {
            // Open the app's default profile (most-recent, else the bundled
            // local one) — the same value the replaced default New Window used.
            // Not `currentServerId`: a value-based `WindowGroup(for:)` dedupes on
            // the presented value, so reusing the focused window's own id would
            // just re-activate it instead of opening a new window.
            openWindow(value: recents.ids.first ?? ProfileDirectory.localProfileID)
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])

        Divider()

        // Close the focused session tab. Disabled when no tab is selected, so the
        // ⌘W keystroke falls through to the system Close Window — the same
        // behavior the old hidden `closeTabShortcut` button gave, now discoverable
        // in the File menu.
        Button("Close Session") { model?.closeSession() }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(model?.canCloseSession != true)
    }
}

/// **Edit menu** addition: Copy Last Response (⌘⇧C) copies the focused chat's
/// most recent Hermes message. Disabled with no focused window or no agent
/// response yet, so the chord is discoverable but inert when there's nothing to
/// copy.
private struct CopyResponseMenu: View {
    @FocusedValue(\.windowMenu) private var model

    var body: some View {
        Button("Copy Last Response") { model?.copyLastResponse() }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model?.canCopyLastResponse != true)
    }
}

/// **View menu** leading group: the sidebar toggle (⌃⌘S) and open-session
/// tab-cycle items (⌃Tab / ⌃⇧Tab). Reads the focused window's model like the
/// section list below it; disabled with no focused window so the shortcuts stay
/// discoverable.
private struct ViewExtrasMenu: View {
    @FocusedValue(\.windowMenu) private var model

    var body: some View {
        // ⌃⌘S sidebar toggle. On iOS/iPadOS the split-view controller *already*
        // registers a system ⌃⌘S "Show Sidebar" (`toggleSidebar:`) command;
        // adding our own then produces two ⌃⌘S key commands, and when UIKit
        // rebuilds the main menu from the responder chain (the first
        // hardware-key event — e.g. typing the first character in the composer)
        // its strict `UIMenuBuilder` aborts with "Replacement elements contain
        // duplicates", crashing the app. So the explicit shortcut is macOS-only
        // (where SwiftUI does not auto-provide it for our
        // `NavigationSplitView(columnVisibility:)`); iOS relies on the system
        // command, which drives the same bound `columnVisibility`. The menu item
        // itself stays on both for discoverability.
        Button("Toggle Sidebar") { model?.toggleSidebar() }
            .keyboardShortcut(Self.sidebarShortcut)
            .disabled(model == nil)

        Button("Next Session") { model?.selectNextSession() }
            .keyboardShortcut(.tab, modifiers: .control)
            .disabled(model == nil)

        Button("Previous Session") { model?.selectPreviousSession() }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .disabled(model == nil)
    }

    /// The explicit ⌃⌘S shortcut, macOS-only. `nil` on iOS/iPadOS so we don't
    /// duplicate the split view's system-provided ⌃⌘S "Show Sidebar" command
    /// (see the note in `body` — the duplicate crashes UIKit's menu builder).
    private static var sidebarShortcut: KeyboardShortcut? {
        #if os(macOS)
        KeyboardShortcut("s", modifiers: [.command, .control])
        #else
        nil
        #endif
    }
}

/// **Profiles menu**: Switch Server + Switch Hermes Profile submenus for the
/// focused window. No shortcut — pick with mouse/arrows. For *server* profiles,
/// holding ⇧ or ⌘ opens the chosen profile in a new window instead of switching.
private struct ProfilesMenu: View {
    let recents: RecentServers
    @FocusedValue(\.windowMenu) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu("Switch Server") {
            ForEach(model?.serverProfiles ?? []) { profile in
                Toggle(isOn: Binding(
                    get: { model?.currentServerId == profile.id },
                    set: { _ in
                        if MenuModifiers.wantsNewWindow {
                            // Mirror `ServerCommands.openProfile`: record before
                            // opening so a server opened in a new window lands in
                            // Recent Servers like every other open path.
                            recents.record(profile.id)
                            openWindow(value: profile.id)
                        } else {
                            model?.switchServer(profile.id)
                        }
                    }
                )) {
                    Text(profile.name)
                }
            }
            Divider()
            Text("Hold ⇧ or ⌘ to open in a new window")
                .foregroundStyle(.secondary)
        }
        .disabled(model == nil)

        Menu("Switch Hermes Profile") {
            if model?.isLoadingHermesProfiles == true {
                Text("Loading…")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model?.hermesProfiles ?? []) { profile in
                    Toggle(isOn: Binding(
                        get: { model?.activeHermesProfile == profile.name },
                        set: { _ in model?.switchHermes(profile.name) }
                    )) {
                        Text(profile.name)
                    }
                }
            }
        }
        .disabled(model == nil)
    }
}

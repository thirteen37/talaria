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
        // would create a duplicate).
        CommandGroup(after: .sidebar) { SectionMenu() }
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

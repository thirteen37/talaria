import AppKit
import HermesKit
import SwiftUI

// macOS half of the platform seam. The iOS half lives in `Platform/iOS/` and
// defines the same symbols; the `**/iOS/**` / `**/macOS/**` folder excludes in
// `project.yml` compile only one half per target, so neither needs `#if`.

enum Idiom {
    /// macOS is never the compact "phone" idiom — it always runs the desktop UI.
    @MainActor static var isPhone: Bool { false }
}

enum Pasteboard {
    /// Copies `text` to the general pasteboard.
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum MenuModifiers {
    /// True when a "Switch Server" menu item is clicked with ⇧ or ⌘ held — the
    /// Profiles menu reads this to open the chosen profile in a new window
    /// instead of switching in place. macOS reads the live event flags.
    @MainActor static var wantsNewWindow: Bool {
        let flags = NSEvent.modifierFlags
        return flags.contains(.shift) || flags.contains(.command)
    }
}

enum Platform {
    /// macOS can run the bundled local Hermes (`Process` / `OneShotProcess`).
    static var supportsLocalProfile: Bool { true }

    /// macOS authenticates with identity files only; no password + Keychain path.
    static var supportsPasswordAuth: Bool { false }

    /// macOS gates Save on a successful probe (system-ssh + local probe both
    /// work there), recording the discovered Hermes version.
    static var requiresProbeBeforeSave: Bool { true }

    /// The current user's home directory.
    static func defaultHomeDirectory() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }
}

extension View {
    /// No-op on macOS — there is no navigation-bar title display mode.
    func inlineNavigationTitle() -> some View { self }

    /// macOS window subtitle (shown next to the title in the titlebar).
    func platformWindowSubtitle(_ subtitle: String) -> some View {
        navigationSubtitle(subtitle)
    }

    /// Permission-prompt sizing: macOS uses a fixed, comfortably-wide frame.
    func permissionPromptLayout() -> some View {
        padding(20)
            .frame(minWidth: 460, idealWidth: 560, maxWidth: 680)
    }

    /// Identity-file picker: macOS opens an `NSOpenPanel` (modal) when
    /// `isPresented` flips true, then resets the flag.
    func identityFilePicker(isPresented: Binding<Bool>, onPick: @escaping (String) -> Void) -> some View {
        onChange(of: isPresented.wrappedValue) { _, presenting in
            guard presenting else { return }
            isPresented.wrappedValue = false
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.showsHiddenFiles = true
            panel.directoryURL = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh", isDirectory: true)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            onPick(url.path)
        }
    }

    /// Gear toolbar item that opens the profile editor. No-op on macOS — the
    /// app's `Settings` scene (⌘,) owns profile editing there.
    func platformSettingsToolbarItem(action: @escaping () -> Void) -> some View {
        self
    }

    /// Reports whether this window is the one the user is actively looking at,
    /// so the store can suppress notifications for a chat already on screen.
    /// macOS reads `controlActiveState`: only `.key` (this is *the* focused
    /// window) counts as foreground. `.active` is the non-key case — a main
    /// window of the active app that doesn't have keyboard focus, e.g. a second
    /// profile window sitting behind the key one — so treating it as foreground
    /// would wrongly suppress that window's notifications.
    func trackWindowForeground(_ report: @escaping (Bool) -> Void) -> some View {
        background(WindowForegroundReader(report: report))
    }

    /// No-op on macOS — desktop SSH connections aren't suspended when the app
    /// backgrounds, so there's no background→foreground reconnect to trigger.
    /// Mirrors the iOS seam so the shared `chatNotificationRouting` call site
    /// compiles `#if`-free.
    func onResumeFromBackground(_ action: @escaping () -> Void) -> some View { self }

    /// Profile-editor sheet for the desktop window. No-op on macOS — the
    /// `Settings` scene presents the editor instead.
    func platformSettingsSheet<Editor: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder editor: @escaping () -> Editor
    ) -> some View {
        self
    }
}

/// Detail view for a `.tui` session tab. macOS embeds the SwiftTerm terminal;
/// the iOS mirror returns an unavailable placeholder (never reached, since TUI
/// tabs can't be created there).
@MainActor
@ViewBuilder
func platformTUIDetail(tabId: SessionId, spec: TUILaunchSpec?) -> some View {
    if let spec {
        HermesTUIDetailView(tabId: tabId, spec: spec)
    } else {
        ContentUnavailableView(
            "Terminal unavailable",
            systemImage: "exclamationmark.triangle",
            description: Text("The terminal session couldn't be prepared.")
        )
    }
}

/// Two-pane split for desktop surfaces. macOS uses a resizable `HSplitView`.
///
/// `showsSecondary` is a `Binding` purely so the iOS half can clear the call
/// site's selection when the pushed iPhone detail is popped (see the iOS seam).
/// macOS only ever *reads* it — there's no pop to write back — so the setter is
/// never invoked here. `secondaryTitle` is likewise iPhone-only (the pushed
/// page's title) and ignored on macOS, but kept in the signature so the shared
/// call sites compile against both halves.
struct PlatformSplit<Primary: View, Secondary: View>: View {
    @Binding var showsSecondary: Bool
    @ViewBuilder var primary: () -> Primary
    @ViewBuilder var secondary: () -> Secondary

    init(
        showsSecondary: Binding<Bool> = .constant(true),
        secondaryTitle: String? = nil,
        @ViewBuilder primary: @escaping () -> Primary,
        @ViewBuilder secondary: @escaping () -> Secondary
    ) {
        self._showsSecondary = showsSecondary
        self.primary = primary
        self.secondary = secondary
    }

    var body: some View {
        HSplitView {
            primary()
            if showsSecondary { secondary() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Reports the window's foreground state from `controlActiveState`. Fires on
/// appear (so a store built for an already-frontmost window starts correct) and
/// on every transition. Implemented as a background `View` (not a
/// `ViewModifier`) so it doesn't depend on the `ViewModifier.Content` typealias,
/// which collides with an AppKit symbol of the same name in this file.
private struct WindowForegroundReader: View {
    @Environment(\.controlActiveState) private var controlActiveState
    let report: (Bool) -> Void

    private var isForeground: Bool { controlActiveState == .key }

    var body: some View {
        Color.clear
            .onAppear { report(isForeground) }
            .onChange(of: controlActiveState) { _, _ in report(isForeground) }
    }
}

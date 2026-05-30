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

    /// Profile-editor sheet for the desktop window. No-op on macOS — the
    /// `Settings` scene presents the editor instead.
    func platformSettingsSheet<Editor: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder editor: @escaping () -> Editor
    ) -> some View {
        self
    }
}

/// Two-pane split for desktop surfaces. macOS uses a resizable `HSplitView`.
struct PlatformSplit<Primary: View, Secondary: View>: View {
    var showsSecondary: Bool = true
    @ViewBuilder var primary: () -> Primary
    @ViewBuilder var secondary: () -> Secondary

    init(
        showsSecondary: Bool = true,
        @ViewBuilder primary: @escaping () -> Primary,
        @ViewBuilder secondary: @escaping () -> Secondary
    ) {
        self.showsSecondary = showsSecondary
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

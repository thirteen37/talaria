import HermesKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// iOS half of the platform seam — mirror of `Platform/macOS/PlatformSeam.swift`.
// Same symbols, iOS behavior; folder excludes ensure only one half compiles.

enum Idiom {
    /// iPad keeps the desktop UI; only iPhone collapses to the compact stack.
    @MainActor static var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }
}

enum Pasteboard {
    /// Copies `text` to the general pasteboard.
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }
}

enum Platform {
    /// iOS can't run local hermes (no `Process` / `OneShotProcess`); it is
    /// remote-only, so the bundled local profile is hidden.
    static var supportsLocalProfile: Bool { false }

    /// iOS offers password + Keychain auth in addition to identity files.
    static var supportsPasswordAuth: Bool { true }

    /// iOS doesn't gate Save on a probe: password-auth profiles can't be
    /// probed before their secret reaches the Keychain, so capability
    /// discovery happens at first connect. The Probe button stays available as
    /// an optional check (identity-auth profiles).
    static var requiresProbeBeforeSave: Bool { false }

    /// `FileManager.homeDirectoryForCurrentUser` is meaningless in the iOS app
    /// sandbox. iOS is remote-only, so `"~"` lets the remote shell expand it to
    /// whichever home the SSH login lands in.
    static func defaultHomeDirectory() -> String { "~" }
}

extension View {
    /// Inline title keeps vertical space for content instead of the tall
    /// large-title header.
    func inlineNavigationTitle() -> some View {
        navigationBarTitleDisplayMode(.inline)
    }

    /// No window subtitle concept on iOS.
    func platformWindowSubtitle(_ subtitle: String) -> some View { self }

    /// Permission-prompt sizing: on iPhone the fixed 460pt minimum overflows
    /// the screen and clips the prompt. Fill the sheet width and scroll
    /// vertically so a tall payload stays reachable.
    func permissionPromptLayout() -> some View {
        ScrollView {
            padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Identity-file picker: iOS presents a `.fileImporter`. SSH keys are
    /// usually extensionless, so accept any data/item.
    func identityFilePicker(isPresented: Binding<Bool>, onPick: @escaping (String) -> Void) -> some View {
        fileImporter(
            isPresented: isPresented,
            allowedContentTypes: [.data, .item, .text]
        ) { result in
            if case let .success(url) = result {
                onPick(url.path)
            }
        }
    }

    /// Gear toolbar item that opens the profile editor (there's no `Settings`
    /// scene on iOS, so the desktop window surfaces editing itself on iPad).
    func platformSettingsToolbarItem(action: @escaping () -> Void) -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: action) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
                .help("Open settings")
            }
        }
    }

    /// Settings sheet for the desktop window on iPad. The editor supplies its
    /// own navigation per tab (see `SettingsTabs` / `ProfileEditorRoot`), so
    /// this no longer wraps it in a `NavigationStack`.
    func platformSettingsSheet<Editor: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder editor: @escaping () -> Editor
    ) -> some View {
        sheet(isPresented: isPresented) {
            editor()
        }
    }
}

/// Two-pane split for desktop surfaces. iPad uses a plain `HStack` + `Divider`
/// (no draggable splitter, which AppKit's `HSplitView` provides on macOS).
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
        HStack(spacing: 0) {
            primary()
            if showsSecondary {
                Divider()
                secondary()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

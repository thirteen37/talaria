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

    /// Reports whether this window is the one the user is actively looking at,
    /// so the store can suppress notifications for a chat already on screen. iOS
    /// reads `scenePhase`: `.active` ⇒ foreground, `.inactive`/`.background` ⇒
    /// not. (A backgrounded iOS app suspends its connection, so these mostly
    /// fire while active-but-inactive — see the plan's iOS caveat.)
    func trackWindowForeground(_ report: @escaping (Bool) -> Void) -> some View {
        background(WindowForegroundReader(report: report))
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

/// Detail view for a `.tui` session tab. iOS has no local/PTY path, so this is
/// an unavailable placeholder — never reached, since TUI tabs can't be created
/// on iOS (the store's `tuiSpecFactory` is nil there). Mirrors the macOS seam,
/// which embeds the SwiftTerm terminal.
@MainActor
@ViewBuilder
func platformTUIDetail(tabId: SessionId, spec: TUILaunchSpec?) -> some View {
    ContentUnavailableView(
        "Terminal sessions aren't available",
        systemImage: "terminal",
        description: Text("Open this session as a regular chat instead.")
    )
}

/// Two-pane split for desktop surfaces.
///
/// - **iPad** keeps a plain `HStack` + `Divider` (no draggable splitter, which
///   AppKit's `HSplitView` provides on macOS) — the two panes sit side by side.
/// - **iPhone** is too narrow for a two-pane split, so the primary list fills
///   the screen and the secondary is *pushed full-page* onto the surrounding
///   navigation stack (the iPhone Browse sheet's `NavigationStack`, reached via
///   `BrowseDetailView`). `showsSecondary` drives a
///   `navigationDestination(isPresented:)`: a row tap flips the call site's
///   selection → the getter returns `true` → the detail pushes; tapping **Back**
///   makes SwiftUI write `false`, and the call site's setter clears its
///   selection so the list deselects. `secondaryTitle` titles that pushed page.
struct PlatformSplit<Primary: View, Secondary: View>: View {
    @Binding var showsSecondary: Bool
    private let secondaryTitle: String?
    @ViewBuilder var primary: () -> Primary
    @ViewBuilder var secondary: () -> Secondary

    init(
        showsSecondary: Binding<Bool> = .constant(true),
        secondaryTitle: String? = nil,
        @ViewBuilder primary: @escaping () -> Primary,
        @ViewBuilder secondary: @escaping () -> Secondary
    ) {
        self._showsSecondary = showsSecondary
        self.secondaryTitle = secondaryTitle
        self.primary = primary
        self.secondary = secondary
    }

    var body: some View {
        if Idiom.isPhone {
            primary()
                .navigationDestination(isPresented: $showsSecondary) { pushedSecondary }
        } else {
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

    /// The pushed iPhone detail, with the call site's title applied inline so the
    /// full page isn't blank-titled. Detail panes keep their own toolbar/Save.
    @ViewBuilder
    private var pushedSecondary: some View {
        if let secondaryTitle {
            secondary()
                .navigationTitle(secondaryTitle)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            secondary()
        }
    }
}

/// Reports the window's foreground state from `scenePhase`. Fires on appear and
/// on every transition. Implemented as a background `View` (not a
/// `ViewModifier`) to mirror the macOS half, which avoids a `Content` typealias
/// collision with an AppKit symbol.
private struct WindowForegroundReader: View {
    @Environment(\.scenePhase) private var scenePhase
    let report: (Bool) -> Void

    private var isForeground: Bool { scenePhase == .active }

    var body: some View {
        Color.clear
            .onAppear { report(isForeground) }
            .onChange(of: scenePhase) { _, _ in report(isForeground) }
    }
}

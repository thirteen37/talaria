import HermesKit
import PhotosUI
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

enum MenuModifiers {
    /// iPad's Profiles menu switches the server in place only — there's no
    /// "open in a new window" modifier path — so this is always false.
    @MainActor static var wantsNewWindow: Bool { false }
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

    /// iOS devices may have no hardware keyboard, so a `⌥N` key-hint badge would
    /// advertise a shortcut the user can't press. Hide the hint; the shortcut
    /// itself stays wired (a no-op without a keyboard, usable with one).
    static var showsKeyboardShortcutHints: Bool { false }
}

extension View {
    /// Inline title keeps vertical space for content instead of the tall
    /// large-title header.
    func inlineNavigationTitle() -> some View {
        navigationBarTitleDisplayMode(.inline)
    }

    /// No window subtitle concept on iOS.
    func platformWindowSubtitle(_ subtitle: String) -> some View { self }

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

    /// Image picker: iOS presents a `PhotosPicker` (images only, multi-select)
    /// when `isPresented` flips true. Picked items load their `Data`, normalize
    /// off the main actor, then deliver via `onPick`. Mirrors ``identityFilePicker``.
    func imagePicker(
        isPresented: Binding<Bool>,
        onPick: @escaping @MainActor ([ComposerAttachment]) -> Void
    ) -> some View {
        // Hosted in a zero-size background `View` (not a `ViewModifier`) because
        // this file's `Content` symbol collides with a UIKit type, so
        // `ViewModifier.Content` mis-resolves — the same reason the scene-phase
        // readers below are background views.
        background(PhotosImagePickerHost(isPresented: isPresented, onPick: onPick))
    }

    /// Reports whether this window is the one the user is actively looking at,
    /// so the store can suppress notifications for a chat already on screen. iOS
    /// reads `scenePhase`: `.active` ⇒ foreground, `.inactive`/`.background` ⇒
    /// not. (A backgrounded iOS app suspends its connection, so these mostly
    /// fire while active-but-inactive — see the plan's iOS caveat.)
    func trackWindowForeground(_ report: @escaping (Bool) -> Void) -> some View {
        background(WindowForegroundReader(report: report))
    }

    /// No-op on iOS/iPadOS — window geometry is system-managed (Stage Manager,
    /// full screen, split view), and iPhone is single-window. Mirrors the macOS
    /// seam so the shared call site compiles `#if`-free.
    func rememberWindowFrame(for profileId: UUID) -> some View { self }

    /// Fires `action` when the app returns from a real backgrounding (a
    /// `.background` → `.active` round-trip), so the window can probe and, if
    /// needed, rebuild its suspended SSH connection. A bare `.inactive` blip
    /// (control center, app-switcher peek) never fires it. macOS has a no-op
    /// mirror — desktop connections don't suspend on background — so the shared
    /// call site (`chatNotificationRouting`) compiles `#if`-free.
    func onResumeFromBackground(_ action: @escaping () -> Void) -> some View {
        background(BackgroundResumeReader(action: action))
    }

    /// Fires `action` when the app enters the background (`scenePhase ==
    /// .background`) — the last reliable hook before iOS may terminate the
    /// suspended app, so it's where a window persists its cold-relaunch
    /// restoration snapshot. macOS has a no-op mirror (desktop windows aren't
    /// killed-and-restored), so the shared call site compiles `#if`-free.
    func onEnterBackground(_ action: @escaping () -> Void) -> some View {
        background(EnterBackgroundReader(action: action))
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

/// Composer image intake (iOS half of the seam). Normalization is shared via
/// ``ImageNormalizer``; the pasteboard read is macOS-only (iOS pastes through
/// `PasteButton` → ``loadComposerAttachments(from:onEach:)``), so this half
/// exposes just `normalize`.
enum ComposerImage {
    /// Decode + downscale + re-encode raw bytes off the main actor. See
    /// ``ImageNormalizer/normalize(_:displayName:)``.
    static func normalize(_ raw: Data, displayName: String?) -> ComposerAttachment? {
        ImageNormalizer.normalize(raw, displayName: displayName)
    }
}

/// Paste-image control for the composer (iOS half): a `PasteButton` filtered to
/// image content. Pasted providers load + normalize off the main actor (see
/// ``loadComposerAttachments(from:onEach:)``), then deliver via `onPaste`.
@MainActor
@ViewBuilder
func composerPasteControl(onPaste: @escaping @MainActor ([ComposerAttachment]) -> Void) -> some View {
    PasteButton(supportedContentTypes: [.image]) { providers in
        loadComposerAttachments(from: providers) { attachment in
            onPaste([attachment])
        }
    }
    .labelStyle(.iconOnly)
    .help("Paste image")
    .accessibilityLabel("Paste image")
}

/// `imagePicker` backing host: a zero-size background `View` that hosts the
/// `PhotosPicker` selection state and loads each picked item's `Data`,
/// normalizing off the main actor before handing results back. A `View` (not a
/// `ViewModifier`) to avoid this file's `Content` symbol collision.
private struct PhotosImagePickerHost: View {
    @Binding var isPresented: Bool
    let onPick: @MainActor ([ComposerAttachment]) -> Void
    @State private var selection: [PhotosPickerItem] = []

    var body: some View {
        Color.clear
            .photosPicker(isPresented: $isPresented, selection: $selection, matching: .images)
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                let picked = items
                selection = []
                Task {
                    var datas: [Data] = []
                    for item in picked {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            datas.append(data)
                        }
                    }
                    let attachments = await Task.detached {
                        datas.compactMap { ComposerImage.normalize($0, displayName: nil) }
                    }.value
                    onPick(attachments)
                }
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
    private let secondaryIcon: String?
    private let secondarySubtitle: String?
    private let secondaryBadges: [PanelBadge]
    private let secondaryClosable: Bool
    @ViewBuilder var primary: () -> Primary
    @ViewBuilder var secondary: () -> Secondary

    init(
        showsSecondary: Binding<Bool> = .constant(true),
        secondaryTitle: String? = nil,
        secondaryIcon: String? = nil,
        secondarySubtitle: String? = nil,
        secondaryBadges: [PanelBadge] = [],
        secondaryClosable: Bool = true,
        @ViewBuilder primary: @escaping () -> Primary,
        @ViewBuilder secondary: @escaping () -> Secondary
    ) {
        self._showsSecondary = showsSecondary
        self.secondaryTitle = secondaryTitle
        self.secondaryIcon = secondaryIcon
        self.secondarySubtitle = secondarySubtitle
        self.secondaryBadges = secondaryBadges
        self.secondaryClosable = secondaryClosable
        self.primary = primary
        self.secondary = secondary
    }

    var body: some View {
        if Idiom.isPhone {
            // iPhone keeps the nav-push + Back affordance (title shown inline) —
            // adding a header here would double the title.
            primary()
                .navigationDestination(isPresented: $showsSecondary) { pushedSecondary }
        } else {
            HStack(spacing: 0) {
                primary()
                if showsSecondary {
                    Divider()
                    if secondaryClosable {
                        VStack(spacing: 0) {
                            PanelHeader(
                                title: secondaryTitle,
                                systemImage: secondaryIcon,
                                subtitle: secondarySubtitle,
                                badges: secondaryBadges
                            ) { showsSecondary = false }
                            secondary()
                        }
                    } else {
                        secondary()
                    }
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
            secondaryWithMetadata
                .navigationTitle(secondaryTitle)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            secondaryWithMetadata
        }
    }

    /// The pushed page has no `PanelHeader` (the nav bar owns the title), so the
    /// icon / badges / sub-heading the header shows on macOS/iPad would otherwise
    /// be lost on iPhone. Surface them as a metadata strip above the content when
    /// present; fall back to the bare content otherwise.
    @ViewBuilder
    private var secondaryWithMetadata: some View {
        if secondaryBadges.isEmpty, secondarySubtitle == nil, secondaryIcon == nil {
            secondary()
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    if let secondaryIcon {
                        Image(systemName: secondaryIcon)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(secondaryBadges, id: \.self) { PanelBadgeView(badge: $0) }
                    if let secondarySubtitle {
                        Text(secondarySubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                Divider()
                secondary()
            }
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

/// Watches `scenePhase` and fires `action` on a real background→foreground
/// round-trip, gated by ``BackgroundResumeLatch`` so a transient `.inactive`
/// blip never triggers it. Implemented as a background `View` to mirror
/// `WindowForegroundReader`.
private struct BackgroundResumeReader: View {
    @Environment(\.scenePhase) private var scenePhase
    let action: () -> Void
    @State private var latch = BackgroundResumeLatch()

    var body: some View {
        Color.clear
            .onChange(of: scenePhase) { _, phase in
                if latch.note(phase) { action() }
            }
    }
}

/// Fires `action` each time the scene reaches `.background`. Implemented as a
/// background `View` to mirror the other scene-phase readers in this seam.
private struct EnterBackgroundReader: View {
    @Environment(\.scenePhase) private var scenePhase
    let action: () -> Void

    var body: some View {
        Color.clear
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { action() }
            }
    }
}

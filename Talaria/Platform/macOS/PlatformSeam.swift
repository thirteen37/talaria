import AppKit
import HermesKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

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

    /// macOS always has a hardware keyboard, so `⌥N` key-hint badges always point
    /// at a usable shortcut. (The shortcuts themselves stay wired on both
    /// platforms — they're just no-ops without a keyboard — so an iPad with one
    /// attached can still use them even though the hint is hidden.)
    static var showsKeyboardShortcutHints: Bool { true }
}

extension View {
    /// No-op on macOS — there is no navigation-bar title display mode.
    func inlineNavigationTitle() -> some View { self }

    /// macOS window subtitle (shown next to the title in the titlebar).
    func platformWindowSubtitle(_ subtitle: String) -> some View {
        navigationSubtitle(subtitle)
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

    /// Image picker: macOS opens a multi-select `NSOpenPanel` (image types) when
    /// `isPresented` flips true. Selected files are read and normalized off the
    /// main actor, then delivered via `onPick`. Mirrors ``identityFilePicker``.
    func imagePicker(
        isPresented: Binding<Bool>,
        onPick: @escaping @MainActor ([ComposerAttachment]) -> Void
    ) -> some View {
        onChange(of: isPresented.wrappedValue) { _, presenting in
            guard presenting else { return }
            isPresented.wrappedValue = false
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            panel.allowedContentTypes = [.image]
            guard panel.runModal() == .OK else { return }
            let urls = panel.urls
            Task.detached {
                let attachments = urls.compactMap { url -> ComposerAttachment? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return ComposerImage.normalize(data, displayName: url.lastPathComponent)
                }
                await onPick(attachments)
            }
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

    /// Remembers this window's size and position, keyed by the window's launch
    /// profile id. Assigns the host NSWindow a stable frame-autosave name so
    /// AppKit restores the last frame on open and persists changes automatically.
    ///
    /// The key is the `WindowGroup` launch value, not the window's *active*
    /// profile: if the user switches servers in place via the sidebar, frame
    /// changes keep saving under the launch id. This is deliberate — re-keying
    /// mid-session would resize the window on every switch — so each server's
    /// frame is remembered for the window opened *for* that server (the primary
    /// flow, since opening a server spawns a window under its own id).
    func rememberWindowFrame(for profileId: UUID) -> some View {
        background(WindowFrameAutosaver(profileId: profileId))
    }

    /// No-op on macOS — desktop SSH connections aren't suspended when the app
    /// backgrounds, so there's no background→foreground reconnect to trigger.
    /// Mirrors the iOS seam so the shared `chatNotificationRouting` call site
    /// compiles `#if`-free.
    func onResumeFromBackground(_ action: @escaping () -> Void) -> some View { self }

    /// No-op on macOS — desktop windows aren't suspended-and-terminated, so
    /// there's no cold relaunch to persist a restoration snapshot for. Mirrors the
    /// iOS seam so the shared window save path compiles `#if`-free.
    func onEnterBackground(_ action: @escaping () -> Void) -> some View { self }

    /// Profile-editor sheet for the desktop window. No-op on macOS — the
    /// `Settings` scene presents the editor instead.
    func platformSettingsSheet<Editor: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder editor: @escaping () -> Editor
    ) -> some View {
        self
    }
}

/// Composer image intake (macOS half of the seam). Normalization is shared via
/// ``ImageNormalizer``; only the pasteboard read is platform-specific.
enum ComposerImage {
    /// Decode + downscale + re-encode raw bytes off the main actor. See
    /// ``ImageNormalizer/normalize(_:displayName:)``.
    static func normalize(_ raw: Data, displayName: String?) -> ComposerAttachment? {
        ImageNormalizer.normalize(raw, displayName: displayName)
    }

    /// Raw image bytes on the general pasteboard, read on the main actor (the
    /// pasteboard must be touched there) but **not** yet normalized — the caller
    /// normalizes off-main so a large paste doesn't hitch the UI. Prefers raw
    /// image data (a copied screenshot vends PNG/TIFF); falls back to `NSImage`
    /// objects' TIFF bytes for apps that only vend the object representation.
    @MainActor
    static func pasteboardImageData() -> [Data] {
        let pasteboard = NSPasteboard.general
        for type in pasteboard.types ?? [] {
            guard let utType = UTType(type.rawValue), utType.conforms(to: .image),
                  let data = pasteboard.data(forType: type) else { continue }
            // One paste yields one image, even though it's offered in several
            // representations (e.g. png + tiff) — take the first usable one.
            return [data]
        }
        guard let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] else {
            return []
        }
        return images.compactMap { $0.tiffRepresentation }
    }
}

/// Paste-image control for the composer (macOS half): a visible button that
/// reads images off `NSPasteboard`, plus a hidden ⌘⇧V shortcut (same hidden-
/// button pattern as the composer's ⌘L focus button) so it never competes with
/// the text field's own ⌘V.
@MainActor
func composerPasteControl(onPaste: @escaping @MainActor ([ComposerAttachment]) -> Void) -> some View {
    // Read the raw bytes on the main actor, then normalize (decode/downscale/
    // re-encode) off-main so a large paste — e.g. a Retina screenshot — doesn't
    // hitch the UI, matching every other intake path.
    func paste() {
        let datas = ComposerImage.pasteboardImageData()
        guard !datas.isEmpty else { return }
        Task.detached {
            let attachments = datas.compactMap { ComposerImage.normalize($0, displayName: nil) }
            await onPaste(attachments)
        }
    }
    return Button(action: paste) {
        Image(systemName: "doc.on.clipboard")
    }
    .help("Paste image (⌘⇧V)")
    .accessibilityLabel("Paste image")
    .background {
        Button("Paste image", action: paste)
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
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

/// Width the split reserves for the primary pane so a wide secondary can never
/// overflow the window and push its header's close button off-screen. A secondary
/// wider than `region - this` clips its content rather than the close.
///
/// Set to the largest primary minimum across the closable surfaces *except*
/// Kanban, whose board still uses a 420pt minimum pending its own layout fix — so
/// Kanban's close button can still be clipped in a narrow window until that lands.
/// Every other surface caps its primary at ≤ 320pt, so this reservation holds.
private let reservedPrimaryWidth: CGFloat = 320

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
        // Honor the inherited top safe-area inset (window toolbar + the
        // window-center banner strip hosted on the detail-column root, plus any
        // stacked `manageBanner`). The detail root applies the strip via
        // `safeAreaInset(.top)`, which clears the translucent toolbar but does
        // not shrink the `HSplitView`'s layout region — so a top-left `Table`
        // (an NSScrollView with a floating header) would render at y=0 *under*
        // the strip. Reading the cumulative inset here and converting it to
        // explicit top padding — while opting the container out of the
        // OS-managed top inset so the manual padding owns the offset — starts
        // the panes below the strip instead of behind it.
        //
        // The `GeometryReader` must *not* ignore the safe area itself: doing so
        // collapses its reported `safeAreaInsets.top` to 0 (the reader expands
        // into the region it would otherwise be inset by), which would make the
        // padding a no-op. So the reader keeps the inset and only the inner
        // `HSplitView` opts out of the container inset, after the padding.
        GeometryReader { proxy in
            let topInset = proxy.safeAreaInsets.top
            HSplitView {
                primary()
                if showsSecondary {
                    Group {
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
                    // Cap the secondary so the split can't overflow the window:
                    // reserve `reservedPrimaryWidth` for the primary, so the
                    // secondary's trailing edge — and the header's right-aligned
                    // close button — always stays on screen. A no-op until the
                    // window is too narrow to fit both panes; then the secondary's
                    // content clips on the right while the close stays put.
                    // `proxy.size.width` is the detail region (window minus nav).
                    .frame(maxWidth: max(240, proxy.size.width - reservedPrimaryWidth))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, topInset)
            .ignoresSafeArea(.container, edges: .top)
        }
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

/// Attaches a per-profile frame-autosave name to the host window the first time
/// the backing view joins a window. Restores the saved frame, then enables
/// AppKit's automatic save-on-move/resize.
private struct WindowFrameAutosaver: NSViewRepresentable {
    let profileId: UUID

    func makeNSView(context: Context) -> NSView { FrameAutosaveView(profileId: profileId) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class FrameAutosaveView: NSView {
        let profileId: UUID
        init(profileId: UUID) { self.profileId = profileId; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            let name = "ServerWindow-\(profileId.uuidString)"
            // Restore the saved frame (if any), then enable automatic persistence.
            window.setFrameUsingName(NSWindow.FrameAutosaveName(name))
            window.setFrameAutosaveName(NSWindow.FrameAutosaveName(name))
        }
    }
}

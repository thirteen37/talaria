import AppKit
import HermesKit
import SwiftUI

/// Headless renderer that snapshots the three blocking-prompt kinds rendered by
/// ``PermissionPrompt`` to PNGs, used to demonstrate that a clarify `.question`
/// and a `.secret` prompt no longer wear the `.permission` "Permission Required"
/// chrome. Driven by the `-renderPromptShots <dir>` launch flag (see
/// `TalariaLaunchDelegate`); it needs no window/Space, so it works headlessly.
@MainActor
enum PromptShotRenderer {
    /// Builds a representative ``PermissionPromptState`` for each prompt kind from
    /// the same per-kind data the fixture injector uses (``ScreenshotPromptFixture``).
    static func sampleState(_ kind: UserPromptKind) -> PermissionPromptState {
        let request = ScreenshotPromptFixture.request(kind, sessionId: "shot")
        return PermissionPromptState(id: .string("shot"), request: request, kind: kind, respond: { _ in })
    }

    private static func card(_ kind: UserPromptKind, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(caption)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            // `PermissionPrompt` now draws its own card chrome (fill + kind-tinted
            // border). Adding a second background/overlay here would stack a gray
            // separator border over the tint, hiding the very thing this shot
            // showcases — so just let the card render itself.
            PermissionPrompt(state: sampleState(kind), select: { _ in }, cancel: {})
        }
    }

    private static var gallery: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Blocking prompts by kind")
                .font(.title2.bold())
            card(.permission, caption: "approval.request → .permission (unchanged: orange, green allow/deny)")
            card(.question, caption: "clarify.request → .question (no header, neutral choice buttons)")
            card(.secret, caption: "secret.request / sudo.request → .secret (lock icon, no \"Permission Required\")")
        }
        .padding(28)
        .frame(width: 660)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    /// Renders each kind individually plus a combined gallery to `dir`.
    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        write(AnyView(gallery), to: dir.appendingPathComponent("prompts-gallery.png"))
        for (kind, name) in [(UserPromptKind.permission, "permission"), (.question, "question"), (.secret, "secret")] {
            let view = PermissionPrompt(state: sampleState(kind), select: { _ in }, cancel: {})
                // The inline card is `maxWidth: .infinity`; with no enclosing
                // width here (unlike `gallery`, which frames its cards at 660pt)
                // it would collapse to intrinsic width. Pin a comfortable width to
                // restore the sizing the old `permissionPromptLayout()` gave.
                .frame(width: 560)
                .padding(24)
                .background(Color(nsColor: .underPageBackgroundColor))
            write(AnyView(view), to: dir.appendingPathComponent("prompt-\(name).png"))
        }
    }

    private static func write(_ view: AnyView, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}

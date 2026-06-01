import AppKit
import SwiftUI

/// Replaces the default "About Talaria" menu item so the standard macOS About
/// panel renders a custom **credits** blob with clickable repository, issues,
/// upstream, and license links beneath the version/copyright lines.
///
/// Keeping the native panel (rather than a bespoke window) is deliberate: it
/// already shows the app icon, name, `CFBundleShortVersionString`,
/// `CFBundleVersion`, and `NSHumanReadableCopyright` for free.
struct AboutCommand: View {
    var body: some View {
        Button("About Talaria") {
            NSApplication.shared.orderFrontStandardAboutPanel(
                options: [.credits: Self.credits]
            )
        }
    }

    /// A row of clickable links. `NSAttributedString` `.link` runs render as
    /// real hyperlinks in the standard About panel, opening in the browser.
    private static let credits: NSAttributedString = {
        let links: [(label: String, url: String)] = [
            ("Repository", "https://github.com/thirteen37/talaria"),
            ("Issues", "https://github.com/thirteen37/talaria/issues"),
            ("Hermes Agent", "https://github.com/NousResearch/hermes-agent"),
            ("MIT License", "https://github.com/thirteen37/talaria/blob/main/LICENSE"),
            ("Open-Source Licenses", "https://github.com/thirteen37/talaria/blob/main/ACKNOWLEDGEMENTS.md"),
        ]

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let result = NSMutableAttributedString()
        for (index, link) in links.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(
                    string: "  ·  ",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .paragraphStyle: paragraph,
                    ]
                ))
            }
            result.append(NSAttributedString(
                string: link.label,
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .link: URL(string: link.url) as Any,
                    .paragraphStyle: paragraph,
                ]
            ))
        }
        return result
    }()
}

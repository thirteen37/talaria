import HermesKit
import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#endif

/// Maps the pure ``YAMLTokenKind`` tokens to platform colors and builds the
/// highlighted attributed string shared by both the read-only YAML pane (as a
/// SwiftUI `Text`) and the editable `NSTextView`/`UITextView`. Colors are
/// system/semantic so they adapt to light and dark mode. Mirrors the enum-wrapper
/// style of `Markdown.swift`.
enum YAMLHighlightTheme {
    /// The monospaced base font for both panes, matching the previous
    /// `.font(.system(.body, design: .monospaced))` on each platform. On iOS the
    /// font is Dynamic Type-scaled via `UIFontMetrics` (from the body base size)
    /// so it tracks the user's text-size setting; the editor additionally sets
    /// `adjustsFontForContentSizeCategory` so it rescales live while open.
    static var monospacedFont: PlatformFont {
        #if os(macOS)
        return .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        #else
        let base = UIFont.monospacedSystemFont(ofSize: UIFont.labelFontSize, weight: .regular)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
        #endif
    }

    /// Foreground color for untokenized text (the AppKit/UIKit base color so the
    /// editor matches the surrounding label color in both appearances).
    static var defaultTextColor: PlatformColor {
        #if os(macOS)
        return .labelColor
        #else
        return .label
        #endif
    }

    private static var punctuationColor: PlatformColor {
        #if os(macOS)
        return .secondaryLabelColor
        #else
        return .secondaryLabel
        #endif
    }

    static func color(for kind: YAMLTokenKind) -> PlatformColor {
        switch kind {
        case .comment: return .systemGreen
        case .key: return .systemBlue
        case .string: return .systemRed
        case .scalar: return .systemPurple
        case .punctuation: return punctuationColor
        }
    }

    /// Base attributes (monospaced font + default color) applied across the whole
    /// string before per-token colors. Shared so the editor's `textStorage` reset
    /// and the read-only builder stay in sync.
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: monospacedFont, .foregroundColor: defaultTextColor]
    }

    /// Builds a highlighted attributed string: the monospaced base font plus a
    /// per-token foreground color. Used by the read-only pane and as the shared
    /// attribute-application routine for the editor.
    static func attributed(_ text: String, font: PlatformFont = monospacedFont) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: defaultTextColor]
        )
        apply(to: result, text: text)
        return result
    }

    /// Applies per-token foreground colors onto an already-base-styled storage,
    /// skipping any token whose range falls outside the current length (the text
    /// may have changed between lexing and application during a live edit).
    static func apply(to storage: NSMutableAttributedString, text: String) {
        let length = (text as NSString).length
        for token in YAMLSyntaxHighlighter.tokens(in: text) {
            let range = token.range
            guard range.location >= 0, range.location + range.length <= length else { continue }
            storage.addAttribute(.foregroundColor, value: color(for: token.kind), range: range)
        }
    }
}

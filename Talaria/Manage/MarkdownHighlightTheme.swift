import HermesKit
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Maps the pure ``MarkdownTokenKind`` tokens to platform colors and font traits
/// and builds the highlighted attributed string shared by both the read-only
/// soul pane (as a SwiftUI `Text`) and the editable `NSTextView`/`UITextView`.
/// Colors are system/semantic so they adapt to light and dark mode. Mirrors
/// ``YAMLHighlightTheme`` (and reuses its monospaced base font / default color so
/// the two editors stay visually consistent).
enum MarkdownHighlightTheme {
    static var monospacedFont: PlatformFont { YAMLHighlightTheme.monospacedFont }
    static var defaultTextColor: PlatformColor { YAMLHighlightTheme.defaultTextColor }

    private static var secondaryColor: PlatformColor {
        #if os(macOS)
        return .secondaryLabelColor
        #else
        return .secondaryLabel
        #endif
    }

    /// Base attributes (monospaced font + default color) applied across the whole
    /// string before per-token colors. Shared so the editor's `textStorage` reset
    /// and the read-only builder stay in sync.
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: monospacedFont, .foregroundColor: defaultTextColor]
    }

    /// Builds a highlighted attributed string: the monospaced base font plus
    /// per-token color/trait. Used by the read-only pane and as the shared
    /// attribute-application routine for the editor.
    static func attributed(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: baseAttributes)
        apply(to: result, text: text)
        return result
    }

    /// Applies per-token foreground colors and bold/italic font variants onto an
    /// already-base-styled storage, skipping any token whose range falls outside
    /// the current length (the text may have changed between lexing and
    /// application during a live edit). The three font variants are computed once
    /// per call rather than per token.
    static func apply(to storage: NSMutableAttributedString, text: String) {
        let length = (text as NSString).length
        let boldFont = variant(bold: true, italic: false)
        let italicFont = variant(bold: false, italic: true)
        for token in MarkdownSyntaxHighlighter.tokens(in: text) {
            let range = token.range
            guard range.location >= 0, range.location + range.length <= length else { continue }
            if let color = color(for: token.kind) {
                storage.addAttribute(.foregroundColor, value: color, range: range)
            }
            switch token.kind {
            case .heading, .strong:
                storage.addAttribute(.font, value: boldFont, range: range)
            case .emphasis:
                storage.addAttribute(.font, value: italicFont, range: range)
            default:
                break
            }
        }
    }

    private static func color(for kind: MarkdownTokenKind) -> PlatformColor? {
        switch kind {
        case .heading: return .systemBlue
        case .code: return .systemPurple
        case .listMarker: return .systemOrange
        case .blockquote: return .systemGreen
        case .link: return .systemTeal
        case .url, .punctuation, .thematicBreak: return secondaryColor
        // Strong/emphasis carry weight via font traits only, keeping the body
        // text's default color so bold/italic prose stays readable.
        case .strong, .emphasis: return nil
        }
    }

    /// A bold and/or italic variant of the monospaced base font via its font
    /// descriptor (no `NSFontManager`, which is main-actor isolated). Falls back
    /// to the base font when the family has no matching face.
    private static func variant(bold: Bool, italic: Bool) -> PlatformFont {
        let base = monospacedFont
        #if os(macOS)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        guard !traits.isEmpty else { return base }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
        #else
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty, let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: descriptor, size: base.pointSize)
        #endif
    }
}

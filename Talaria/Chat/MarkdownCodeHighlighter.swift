import Highlightr
import MarkdownUI
import SwiftUI

/// A MarkdownUI ``CodeSyntaxHighlighter`` that colors fenced code blocks with
/// Highlightr (highlight.js over JavaScriptCore). The highlighter is synchronous
/// — it runs during view rendering on the main actor — so the costly `Highlightr`
/// instances (each spins up a `JSContext`) are cached per appearance behind a
/// main-actor singleton and created lazily.
struct TalariaCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    let colorScheme: ColorScheme
    /// True while the enclosing message is the actively-streaming last block. The
    /// content-keyed memo can't help here — `code` grows every token, so each
    /// render is a fresh key — so highlighting a streaming block once per token is
    /// O(n²) synchronous JS on the main thread. While streaming we skip Highlightr
    /// entirely and return plain text (MarkdownUI's codeBlock style still applies
    /// the monospaced font); the block is highlighted once when the text settles.
    var isStreaming: Bool = false

    func highlightCode(_ code: String, language: String?) -> Text {
        guard !isStreaming else { return Text(code) }
        // MarkdownUI invokes this from a view body, i.e. the main actor; assume
        // that isolation so we can touch the main-actor-confined Highlightr cache
        // without hopping actors (Highlightr is not Sendable).
        return MainActor.assumeIsolated {
            HighlightrCache.shared.highlight(code, language: language, colorScheme: colorScheme)
        }
    }
}

/// Caches one `Highlightr` per appearance plus a bounded memo of highlighted
/// output. Confined to the main actor because `Highlightr`/`JSContext` are not
/// `Sendable` and all use is during rendering.
@MainActor
private final class HighlightrCache {
    static let shared = HighlightrCache()

    private var light: Highlightr?
    private var dark: Highlightr?

    // SwiftUI re-renders the whole Markdown view on every update, so without a
    // memo every visible code block re-runs the synchronous JS highlighter on
    // each unrelated re-render (scroll, a sibling message arriving, …). Memoize
    // by content + language + appearance and evict in insertion order so a
    // completed block is highlighted once. (Streaming still misses every token
    // — its `code` grows each update — which is the same cost as before; this
    // only spares the steady state.)
    private struct Key: Hashable {
        let code: String
        let language: String?
        let dark: Bool
    }

    private var memo: [Key: Text] = [:]
    private var memoOrder: [Key] = []
    private let memoLimit = 64

    func highlight(_ code: String, language: String?, colorScheme: ColorScheme) -> Text {
        let key = Key(code: code, language: language, dark: colorScheme == .dark)
        if let cached = memo[key] {
            return cached
        }
        let result = render(code, language: language, colorScheme: colorScheme)
        memo[key] = result
        memoOrder.append(key)
        if memoOrder.count > memoLimit {
            memo.removeValue(forKey: memoOrder.removeFirst())
        }
        return result
    }

    private func highlighter(for colorScheme: ColorScheme) -> Highlightr? {
        switch colorScheme {
        case .dark:
            if dark == nil {
                dark = makeHighlighter(theme: "atom-one-dark")
            }
            return dark
        default:
            if light == nil {
                light = makeHighlighter(theme: "xcode")
            }
            return light
        }
    }

    private func makeHighlighter(theme: String) -> Highlightr? {
        let highlightr = Highlightr()
        _ = highlightr?.setTheme(to: theme)
        return highlightr
    }

    private func render(_ code: String, language: String?, colorScheme: ColorScheme) -> Text {
        guard let highlightr = highlighter(for: colorScheme),
              let highlighted = highlightr.highlight(code, as: language)
        else {
            // Unknown language or highlighting failed — fall back to plain text.
            // No explicit font: MarkdownUI's codeBlock style applies the
            // monospaced, `.em`-scaled (Dynamic Type-aware) font to the label,
            // keeping this consistent with the highlighted path below.
            return Text(code)
        }
        // Strip Highlightr's per-run font (a fixed-point Courier) so MarkdownUI's
        // codeBlock font sizing wins — otherwise the hardcoded size would ignore
        // the theme's `.em(0.94)` and Dynamic Type. Per-run colors are kept, so
        // the syntax highlighting survives.
        let mutable = NSMutableAttributedString(attributedString: highlighted)
        mutable.removeAttribute(.font, range: NSRange(location: 0, length: mutable.length))
        return Text(AttributedString(mutable))
    }
}

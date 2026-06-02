import HermesKit
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A SwiftUI text editor that syntax-highlights live, against a pluggable theme
/// (YAML or Markdown — see the `.yaml` / `.markdown` factories). SwiftUI's
/// `TextEditor` binds only to a plain `String` and has no attributed-text editor
/// before macOS 15 / iOS 18, so this bridges to `NSTextView` (macOS) /
/// `UITextView` (iOS) — the codebase's one `ViewRepresentable`.
///
/// On each edit it writes the text back and calls `onChange` *immediately* (so
/// per-keystroke logic like `ConfigEditingState.yamlChanged()`'s parse-error
/// banner / dirty / Save keeps firing), then **debounces** the visual
/// re-highlight so a large document stays responsive while typing.
struct HighlightingTextEditor: View {
    @Binding var text: String
    var onChange: () -> Void = {}
    /// Font + default color applied across the whole string before per-token
    /// styling. From the theme (`YAMLHighlightTheme` / `MarkdownHighlightTheme`).
    let baseAttributes: [NSAttributedString.Key: Any]
    /// Applies per-token attributes onto an already-base-styled storage.
    let highlight: (NSMutableAttributedString, String) -> Void

    var body: some View {
        Representable(text: $text, onChange: onChange, baseAttributes: baseAttributes, highlight: highlight)
    }
}

extension HighlightingTextEditor {
    /// YAML-highlighting editor (the config editor).
    static func yaml(text: Binding<String>, onChange: @escaping () -> Void) -> HighlightingTextEditor {
        HighlightingTextEditor(
            text: text,
            onChange: onChange,
            baseAttributes: YAMLHighlightTheme.baseAttributes,
            highlight: { YAMLHighlightTheme.apply(to: $0, text: $1) }
        )
    }

    /// Markdown-highlighting editor (SOUL.md / personality prompts).
    static func markdown(text: Binding<String>, onChange: @escaping () -> Void = {}) -> HighlightingTextEditor {
        HighlightingTextEditor(
            text: text,
            onChange: onChange,
            baseAttributes: MarkdownHighlightTheme.baseAttributes,
            highlight: { MarkdownHighlightTheme.apply(to: $0, text: $1) }
        )
    }
}

// MARK: - Shared highlighting

private let highlightDebounce: TimeInterval = 0.18

/// Re-lexes `text` and rewrites `storage`'s attributes in place. Only attributes
/// change (never the characters), so the insertion point and selection are
/// preserved by construction.
private func rehighlight(
    _ storage: NSMutableAttributedString,
    text: String,
    baseAttributes: [NSAttributedString.Key: Any],
    highlight: (NSMutableAttributedString, String) -> Void
) {
    let full = NSRange(location: 0, length: (text as NSString).length)
    storage.beginEditing()
    storage.setAttributes(baseAttributes, range: full)
    highlight(storage, text)
    storage.endEditing()
}

#if os(macOS)

extension HighlightingTextEditor {
    struct Representable: NSViewRepresentable {
        @Binding var text: String
        var onChange: () -> Void
        let baseAttributes: [NSAttributedString.Key: Any]
        let highlight: (NSMutableAttributedString, String) -> Void

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeNSView(context: Context) -> NSScrollView {
            let scrollView = NSTextView.scrollableTextView()
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
            textView.delegate = context.coordinator
            textView.isRichText = false
            textView.allowsUndo = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isContinuousSpellCheckingEnabled = false
            textView.textContainerInset = NSSize(width: 4, height: 6)
            textView.drawsBackground = false
            textView.string = text
            textView.typingAttributes = baseAttributes
            if let storage = textView.textStorage {
                rehighlight(storage, text: text, baseAttributes: baseAttributes, highlight: highlight)
            }
            return scrollView
        }

        func updateNSView(_ scrollView: NSScrollView, context: Context) {
            context.coordinator.parent = self
            guard let textView = scrollView.documentView as? NSTextView else { return }
            // Only replace on a genuine external change (mode switch / reload),
            // never echo the user's in-progress edit back over itself.
            guard textView.string != text else { return }
            let selected = textView.selectedRange()
            textView.string = text
            let location = min(selected.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.typingAttributes = baseAttributes
            if let storage = textView.textStorage {
                rehighlight(storage, text: text, baseAttributes: baseAttributes, highlight: highlight)
            }
        }

        @MainActor
        final class Coordinator: NSObject, NSTextViewDelegate {
            var parent: Representable
            private var pending: Task<Void, Never>?

            init(_ parent: Representable) { self.parent = parent }

            func textDidChange(_ notification: Notification) {
                guard let textView = notification.object as? NSTextView else { return }
                parent.text = textView.string
                parent.onChange()
                scheduleHighlight(for: textView)
            }

            // The debounce runs as a main-actor Task (inherited from this
            // `@MainActor` coordinator), so the text view never crosses an
            // isolation boundary and its main-actor state is safe to touch.
            private func scheduleHighlight(for textView: NSTextView) {
                pending?.cancel()
                let baseAttributes = parent.baseAttributes
                let highlight = parent.highlight
                pending = Task { [weak textView] in
                    try? await Task.sleep(for: .seconds(highlightDebounce))
                    guard !Task.isCancelled, let textView, let storage = textView.textStorage else { return }
                    rehighlight(storage, text: textView.string, baseAttributes: baseAttributes, highlight: highlight)
                }
            }
        }
    }
}

#else

extension HighlightingTextEditor {
    struct Representable: UIViewRepresentable {
        @Binding var text: String
        var onChange: () -> Void
        let baseAttributes: [NSAttributedString.Key: Any]
        let highlight: (NSMutableAttributedString, String) -> Void

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeUIView(context: Context) -> UITextView {
            let textView = UITextView()
            textView.delegate = context.coordinator
            // The base font is UIFontMetrics-scaled, so let UIKit rescale it live
            // when the user changes their text size while the editor is open.
            textView.adjustsFontForContentSizeCategory = true
            textView.autocorrectionType = .no
            textView.autocapitalizationType = .none
            textView.spellCheckingType = .no
            textView.smartQuotesType = .no
            textView.smartDashesType = .no
            textView.smartInsertDeleteType = .no
            textView.backgroundColor = .clear
            textView.textContainerInset = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
            textView.typingAttributes = baseAttributes
            textView.text = text
            rehighlight(textView.textStorage, text: text, baseAttributes: baseAttributes, highlight: highlight)
            return textView
        }

        func updateUIView(_ textView: UITextView, context: Context) {
            context.coordinator.parent = self
            guard textView.text != text else { return }
            let selected = textView.selectedRange
            textView.text = text
            let location = min(selected.location, (text as NSString).length)
            textView.selectedRange = NSRange(location: location, length: 0)
            textView.typingAttributes = baseAttributes
            rehighlight(textView.textStorage, text: text, baseAttributes: baseAttributes, highlight: highlight)
        }

        @MainActor
        final class Coordinator: NSObject, UITextViewDelegate {
            var parent: Representable
            private var pending: Task<Void, Never>?

            init(_ parent: Representable) { self.parent = parent }

            func textViewDidChange(_ textView: UITextView) {
                parent.text = textView.text
                parent.onChange()
                scheduleHighlight(for: textView)
            }

            // The debounce runs as a main-actor Task (inherited from this
            // `@MainActor` coordinator), so the text view never crosses an
            // isolation boundary and its main-actor state is safe to touch.
            private func scheduleHighlight(for textView: UITextView) {
                pending?.cancel()
                let baseAttributes = parent.baseAttributes
                let highlight = parent.highlight
                pending = Task { [weak textView] in
                    try? await Task.sleep(for: .seconds(highlightDebounce))
                    guard !Task.isCancelled, let textView else { return }
                    let selected = textView.selectedRange
                    rehighlight(textView.textStorage, text: textView.text ?? "", baseAttributes: baseAttributes, highlight: highlight)
                    textView.selectedRange = selected
                    textView.typingAttributes = baseAttributes
                }
            }
        }
    }
}

#endif

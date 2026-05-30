import HermesKit
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A SwiftUI text editor that syntax-highlights YAML live. SwiftUI's `TextEditor`
/// binds only to a plain `String` and has no attributed-text editor before
/// macOS 15 / iOS 18, so this bridges to `NSTextView` (macOS) / `UITextView`
/// (iOS) — the codebase's one `ViewRepresentable`.
///
/// On each edit it writes the text back and calls `onChange` *immediately* (so
/// the parse-error banner / dirty / Save logic in `ConfigEditingState.yamlChanged()`
/// keeps firing per keystroke), then **debounces** the visual re-highlight so a
/// large config stays responsive while typing.
struct HighlightingTextEditor: View {
    @Binding var text: String
    var onChange: () -> Void

    var body: some View {
        Representable(text: $text, onChange: onChange)
    }
}

// MARK: - Shared highlighting

private let highlightDebounce: TimeInterval = 0.18

/// Re-lexes `text` and rewrites `storage`'s attributes in place. Only attributes
/// change (never the characters), so the insertion point and selection are
/// preserved by construction.
private func rehighlight(_ storage: NSMutableAttributedString, text: String) {
    let full = NSRange(location: 0, length: (text as NSString).length)
    storage.beginEditing()
    storage.setAttributes(YAMLHighlightTheme.baseAttributes, range: full)
    YAMLHighlightTheme.apply(to: storage, text: text)
    storage.endEditing()
}

#if os(macOS)

extension HighlightingTextEditor {
    struct Representable: NSViewRepresentable {
        @Binding var text: String
        var onChange: () -> Void

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
            textView.font = YAMLHighlightTheme.monospacedFont
            textView.textContainerInset = NSSize(width: 4, height: 6)
            textView.drawsBackground = false
            textView.string = text
            textView.typingAttributes = YAMLHighlightTheme.baseAttributes
            if let storage = textView.textStorage { rehighlight(storage, text: text) }
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
            textView.typingAttributes = YAMLHighlightTheme.baseAttributes
            if let storage = textView.textStorage { rehighlight(storage, text: text) }
        }

        final class Coordinator: NSObject, NSTextViewDelegate {
            var parent: Representable
            private var pending: DispatchWorkItem?

            init(_ parent: Representable) { self.parent = parent }

            func textDidChange(_ notification: Notification) {
                guard let textView = notification.object as? NSTextView else { return }
                parent.text = textView.string
                parent.onChange()
                scheduleHighlight(for: textView)
            }

            private func scheduleHighlight(for textView: NSTextView) {
                pending?.cancel()
                let work = DispatchWorkItem { [weak textView] in
                    guard let textView, let storage = textView.textStorage else { return }
                    rehighlight(storage, text: textView.string)
                }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + highlightDebounce, execute: work)
            }
        }
    }
}

#else

extension HighlightingTextEditor {
    struct Representable: UIViewRepresentable {
        @Binding var text: String
        var onChange: () -> Void

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeUIView(context: Context) -> UITextView {
            let textView = UITextView()
            textView.delegate = context.coordinator
            textView.font = YAMLHighlightTheme.monospacedFont
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
            textView.typingAttributes = YAMLHighlightTheme.baseAttributes
            textView.text = text
            rehighlight(textView.textStorage, text: text)
            return textView
        }

        func updateUIView(_ textView: UITextView, context: Context) {
            context.coordinator.parent = self
            guard textView.text != text else { return }
            let selected = textView.selectedRange
            textView.text = text
            let location = min(selected.location, (text as NSString).length)
            textView.selectedRange = NSRange(location: location, length: 0)
            textView.typingAttributes = YAMLHighlightTheme.baseAttributes
            rehighlight(textView.textStorage, text: text)
        }

        final class Coordinator: NSObject, UITextViewDelegate {
            var parent: Representable
            private var pending: DispatchWorkItem?

            init(_ parent: Representable) { self.parent = parent }

            func textViewDidChange(_ textView: UITextView) {
                parent.text = textView.text
                parent.onChange()
                scheduleHighlight(for: textView)
            }

            private func scheduleHighlight(for textView: UITextView) {
                pending?.cancel()
                let work = DispatchWorkItem { [weak textView] in
                    guard let textView else { return }
                    let selected = textView.selectedRange
                    rehighlight(textView.textStorage, text: textView.text ?? "")
                    textView.selectedRange = selected
                    textView.typingAttributes = YAMLHighlightTheme.baseAttributes
                }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + highlightDebounce, execute: work)
            }
        }
    }
}

#endif

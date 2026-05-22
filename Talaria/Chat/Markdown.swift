import SwiftUI

enum Markdown {
    static func attributedString(_ text: String) -> AttributedString {
        do {
            return try AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        } catch {
            return AttributedString(text)
        }
    }
}

struct MarkdownText: View {
    let text: String

    var body: some View {
        Text(Markdown.attributedString(text))
            .textSelection(.enabled)
    }
}

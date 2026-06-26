import MarkdownUI
import SwiftUI

/// The single chokepoint for rendering chat message text. Backed by MarkdownUI
/// so it renders comprehensive CommonMark + GitHub-Flavored markdown (headings,
/// tables, fenced code, lists, task lists, blockquotes, strikethrough, …) with
/// syntax-highlighted code blocks, while keeping today's per-call styling.
///
/// `style` carries what an outer `.font`/`.foregroundStyle` used to: MarkdownUI's
/// `Markdown` view ignores ambient font/color, so the reasoning and tool surfaces
/// pass `.callout`/`.calloutSecondary` to keep their smaller, dimmed look.
struct MarkdownText: View {
    enum Style { case body, callout, calloutSecondary, plain }

    let text: String
    var style: Style = .body
    /// Forwarded to the code highlighter: while the message is still streaming,
    /// fenced code blocks render unhighlighted to avoid re-running the JS
    /// highlighter on every token. No effect on the `.plain` style (no code
    /// highlighting there).
    var isStreaming: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch style {
        case .plain:
            // Whitespace-preserving inline rendering for raw machine output —
            // tool-result and permission payloads (logs, command output, file
            // snippets). Block markdown would collapse their single newlines into
            // spaces and reinterpret leading #/>/-/| as block markup, so those
            // surfaces keep the prior `inlineOnlyPreservingWhitespace` behavior:
            // newlines preserved, only inline emphasis/links interpreted.
            Text(Self.inlinePreserving(text))
                .font(.callout)
                .textSelection(.enabled)
        case .body, .callout, .calloutSecondary:
            Markdown(text)
                .markdownTheme(.talaria(style))
                .markdownCodeSyntaxHighlighter(
                    TalariaCodeSyntaxHighlighter(colorScheme: colorScheme, isStreaming: isStreaming)
                )
                .textSelection(.enabled)
        }
    }

    private static func inlinePreserving(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

extension Theme {
    /// The single source of truth for Talaria's chat markdown styling. Based on
    /// `Theme.basic`, scaled and recolored to sit inside the chat's per-kind
    /// bubbles without dwarfing them. `Color.secondary.opacity(...)` is used for
    /// surfaces so they adapt to light/dark, matching the kind-background palette.
    ///
    /// `@MainActor` because the per-block closures it builds call main-actor View
    /// modifiers; it's only ever constructed from `MarkdownText.body`.
    @MainActor
    static func talaria(_ style: MarkdownText.Style) -> Theme {
        // Callout sits a touch below body; the secondary variant also dims the
        // text. `.em` on the base `text` style multiplies every block's scale, so
        // headings and code stay proportional to the chosen base size.
        let baseScale: CGFloat = style == .body ? 1 : 0.94
        let textColor: Color = style == .calloutSecondary ? .secondary : .primary

        return Theme.basic
            .text {
                ForegroundColor(textColor)
                FontSize(.em(baseScale))
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.94))
                BackgroundColor(.secondary.opacity(0.12))
            }
            .link {
                ForegroundColor(.accentColor)
            }
            // Scale headings DOWN from Theme.basic's 2 / 1.5 / 1.17 ems so a
            // leading `#` doesn't tower over a chat bubble.
            .heading1 { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.8), bottom: .em(0.4))
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.25))
                    }
            }
            .heading2 { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.8), bottom: .em(0.4))
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.15))
                    }
            }
            .heading3 { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.8), bottom: .em(0.4))
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.05))
                    }
            }
            .codeBlock { configuration in
                // Code blocks WRAP; they must not be wrapped in a horizontal
                // `ScrollView`. A horizontal scroll view always proposes an
                // *unbounded* width to its child, regardless of the definite
                // width the outer vertical `ScrollView` hands down. That nil-width
                // proposal forced MarkdownUI's deeply nested stacks into SwiftUI's
                // exponential ideal-size layout pass, which never converged and
                // permanently froze the app when scrolling back through a
                // transcript (the LazyVStack re-measures earlier code rows as they
                // materialize). Rendering the label directly keeps the definite
                // width, so layout is a single linear pass. Long lines wrap.
                configuration.label
                    .relativeLineSpacing(.em(0.15))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.94))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.secondary.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .markdownMargin(top: .em(0.4), bottom: .em(0.8))
            }
            .table { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(TableBorderStyle(color: .secondary.opacity(0.3)))
                    .markdownMargin(top: .em(0.4), bottom: .em(0.8))
            }
            .blockquote { configuration in
                configuration.label
                    .markdownTextStyle {
                        ForegroundColor(.secondary)
                    }
                    .relativePadding(.leading, length: .em(1))
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.4))
                            .frame(width: 3)
                    }
                    .markdownMargin(top: .em(0.4), bottom: .em(0.8))
            }
    }
}

import SwiftUI

/// Visual treatment for an ``EntityLink``, matched to its surrounding context.
enum EntityLinkStyle {
    /// Inherits the ambient foreground (e.g. `.secondary` in the status bar) and
    /// only reveals its tappability on hover. For UI chrome where an accent tint
    /// would be noise.
    case subtle
    /// Accent-tinted, like a hyperlink. For list/table cells where the link is
    /// the primary content of the cell.
    case prominent
}

/// A tappable mention of an entity that routes to the page managing it.
///
/// Wraps its `label` in a plain button that asks the window's
/// ``WindowNavigator`` to ``WindowNavigator/open(_:)`` the ``EntityRef``. If no
/// navigator is in the environment (previews, the Settings scene, anywhere
/// outside a server window) it degrades to an inert label rather than crashing,
/// so call sites can drop it in unconditionally.
///
/// Call sites keep their own `.accessibilityLabel` by applying it to the
/// `EntityLink` itself; the button surfaces the label's text as its action name.
struct EntityLink<Label: View>: View {
    let ref: EntityRef
    var style: EntityLinkStyle = .prominent
    @ViewBuilder var label: Label

    @Environment(WindowNavigator.self) private var navigator: WindowNavigator?
    @State private var hovering = false

    var body: some View {
        if let navigator {
            Button {
                navigator.open(ref)
            } label: {
                styledLabel
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        } else {
            // No navigator in scope: render the label inertly.
            label
        }
    }

    @ViewBuilder
    private var styledLabel: some View {
        switch style {
        case .prominent:
            label
                .foregroundStyle(Color.accentColor)
                .underline(hovering, pattern: .solid)
        case .subtle:
            // Inherit the ambient foreground (no accent tint — that would be
            // noise in chrome). On macOS the affordance is revealed by the hover
            // underline. Touch surfaces have no pointer, so `.onHover` never
            // fires; show a persistent underline there so the tap target stays
            // discoverable rather than looking like inert text.
            #if os(iOS)
            label
                .underline(true, pattern: .solid)
            #else
            label
                .underline(hovering, pattern: .solid)
            #endif
        }
    }
}

// MARK: - Terse convenience initializers

extension EntityLink where Label == Text {
    /// A text-only link. `title` is rendered verbatim (entity names are data,
    /// not localizable keys).
    init(_ title: String, ref: EntityRef, style: EntityLinkStyle = .prominent) {
        self.ref = ref
        self.style = style
        self.label = Text(title)
    }
}

extension EntityLink where Label == SwiftUI.Label<Text, Image> {
    /// An icon + text link mirroring `Label(_:systemImage:)`. `title` is rendered
    /// verbatim.
    init(_ title: String, systemImage: String, ref: EntityRef, style: EntityLinkStyle = .prominent) {
        self.ref = ref
        self.style = style
        self.label = SwiftUI.Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

import SwiftUI

/// Window-scoped navigation intent, injected once per window into the
/// environment. ``EntityLink`` taps set ``pendingFocus``; the host window
/// observes it to route to the page (or open the chat), and the target page
/// observes it to pre-select the matching row, then clears it.
///
/// Holding the intent here (rather than a stored closure capturing view
/// `@State`) keeps the hand-off observable on both ends and survives until the
/// destination consumes it.
@MainActor
@Observable
final class WindowNavigator {
    /// Set by an ``EntityLink`` tap. The window routes to `pendingFocus`'s
    /// destination (or opens the chat for a `.session` ref); the destination
    /// page selects the row and resets this to nil.
    var pendingFocus: EntityRef?

    /// Request navigation to `ref`. Equivalent to setting ``pendingFocus``.
    func open(_ ref: EntityRef) { pendingFocus = ref }
}

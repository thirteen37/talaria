import SwiftUI

/// iOS profile-editor entry point. One of the two places that consult
/// `Idiom.isPhone` (the other is `ServerWindowRoot`): iPhone gets the compact
/// push form, iPad gets the same two-pane desktop editor macOS uses.
struct ProfileEditorRoot: View {
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        if Idiom.isPhone {
            // `PhoneProfileEditor` brings its own `NavigationStack`.
            PhoneProfileEditor(onDismiss: onDismiss)
        } else {
            // The iPad two-pane editor needs a `NavigationStack` for its Done /
            // Save toolbar to render (macOS gets this from the Settings window).
            NavigationStack {
                DesktopProfileEditor(onDismiss: onDismiss)
            }
        }
    }
}

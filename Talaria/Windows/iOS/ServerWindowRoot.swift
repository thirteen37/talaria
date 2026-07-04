import SwiftUI

/// iOS window entry point. One of the two places that consult `Idiom.isPhone`
/// (the other is `ProfileEditorRoot`): iPhone gets the compact push stack,
/// iPad gets the same desktop two-pane window macOS uses. macOS's app entry
/// uses `DesktopServerWindow` directly and never reaches this.
struct ServerWindowRoot: View {
    let profileId: UUID

    var body: some View {
        Group {
            if Idiom.isPhone {
                PhoneServerWindow(profileId: profileId)
            } else {
                DesktopServerWindow(profileId: profileId)
            }
        }
        // Step 1 of the incoming Share Sheet hand-off: present the profile picker
        // when `talaria://share` arrives. The chosen window then presents the
        // session picker via `incomingShareRouting` (applied inside the window).
        .incomingShareProfilePicker()
    }
}

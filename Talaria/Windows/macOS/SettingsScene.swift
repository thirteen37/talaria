import SwiftUI

struct SettingsScene: View {
    var body: some View {
        // No frame here: in a macOS Settings scene the per-tab content sizes the
        // window. A frame on the `TabView` itself suppresses the preferences tab
        // bar, so `SettingsTabs` frames each tab's content instead.
        SettingsTabs()
    }
}

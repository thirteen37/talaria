import SwiftUI

/// Empty state shown by surfaces that depend on a local Hermes CLI ("admin")
/// runner — Tools, Updates, Doctor — when no such runner (and, for Doctor, no
/// reachable dashboard) is available. Like `DashboardNotReadyView`, it fills its
/// container so the top banner strip (`safeAreaInset(.top)`) stays pinned to the
/// top of the detail pane instead of being centered with a compact placeholder.
struct CLIUnavailableView: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(description)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

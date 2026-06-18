import SwiftUI

/// Empty state shown by every browse/manage surface while the window's Hermes
/// dashboard client is still nil (spawning, reconnecting, or failed). Fills its
/// container so the top banner strip (`safeAreaInset(.top)`) stays pinned to the
/// top of the detail pane instead of being centered with a compact placeholder.
struct DashboardNotReadyView: View {
    let systemImage: String

    var body: some View {
        ContentUnavailableView(
            "Dashboard not ready",
            systemImage: systemImage,
            description: Text("Waiting for the Hermes dashboard to come online.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

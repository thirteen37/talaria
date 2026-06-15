import SwiftUI

/// Bottom-anchored drawer: a top `Divider`, a consistent ``PanelHeader`` (title +
/// close), then content at a fixed height. Compose under any primary content as a
/// reusable bottom-edge panel mirroring ``PlatformSplit`` on the right edge.
struct BottomPanel<Content: View>: View {
    let title: String?
    var systemImage: String? = nil
    var subtitle: String? = nil
    var badges: [PanelBadge] = []
    let height: CGFloat
    let onClose: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            PanelHeader(
                title: title,
                systemImage: systemImage,
                subtitle: subtitle,
                badges: badges,
                onClose: onClose
            )
            content()
        }
        .frame(height: height)
    }
}

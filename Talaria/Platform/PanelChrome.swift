import SwiftUI

// Shared panel chrome used by every side panel — the right pane (`PlatformSplit`)
// and the bottom pane (`BottomPanel`). Placed directly under `Platform/` (not a
// `macOS/`/`iOS/` subfolder) so both targets compile it: the seam convention
// only excludes folders *named* `macOS/`/`iOS/`.

/// The one consistent close glyph used by every panel header.
struct PanelCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Close")
        .help("Close the panel")
    }
}

/// A standard pill shown in a panel header. Value-typed so styling stays
/// consistent across panels; replaces the per-screen `SkillPill`/`PluginPill`.
struct PanelBadge: Hashable {
    let text: String
    var tint: Color = .secondary
    /// Optional leading SF Symbol (e.g. an "update available" arrow).
    var systemImage: String? = nil
}

/// Renders one `PanelBadge` in the shared tinted-capsule style. Usable in a
/// panel header's metadata row and anywhere a list/table needs the same pill.
struct PanelBadgeView: View {
    let badge: PanelBadge

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage = badge.systemImage {
                Image(systemName: systemImage)
            }
            Text(badge.text)
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(badge.tint.opacity(0.15), in: Capsule())
        .foregroundStyle(badge.tint == .secondary ? Color.secondary : badge.tint)
        .lineLimit(1)
    }
}

/// Consistent panel header: an optional leading SF Symbol, a title, an optional
/// trailing actions slot, and the close button, with a `Divider` underneath.
/// Reused by the right pane (`PlatformSplit`) and the bottom pane (`BottomPanel`).
struct PanelHeader<Actions: View>: View {
    let title: String?
    var systemImage: String? = nil
    var subtitle: String? = nil
    var badges: [PanelBadge] = []
    let onClose: () -> Void
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                }
                if let title {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                actions()
                PanelCloseButton(action: onClose)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, hasMetadata ? 2 : 6)

            if hasMetadata {
                HStack(spacing: 6) {
                    ForEach(badges, id: \.self) { PanelBadgeView(badge: $0) }
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }

            Divider()
        }
    }

    private var hasMetadata: Bool { !badges.isEmpty || subtitle != nil }
}

extension PanelHeader where Actions == EmptyView {
    /// Convenience init for the common case with no trailing actions.
    init(
        title: String?,
        systemImage: String? = nil,
        subtitle: String? = nil,
        badges: [PanelBadge] = [],
        onClose: @escaping () -> Void
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            subtitle: subtitle,
            badges: badges,
            onClose: onClose
        ) { EmptyView() }
    }
}

import HermesKit
import SwiftUI

/// Step 1 of the incoming-share hand-off: pick which server profile receives the
/// shared content. Presented once (claimed by a single window) when
/// `talaria://share` arrives. Picking a profile opens/focuses that profile's
/// window, which then presents the session picker (step 2). No profile/session
/// networking happens here — only the always-present host-app window machinery.
struct IncomingShareProfileSheet: View {
    let profiles: [ServerProfile]
    let onSelect: (UUID) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if profiles.isEmpty {
                    ContentUnavailableView(
                        "No Servers",
                        systemImage: "server.rack",
                        description: Text("Add a server in Talaria before sharing to it.")
                    )
                } else {
                    List(profiles) { profile in
                        Button {
                            onSelect(profile.id)
                        } label: {
                            row(for: profile)
                        }
                        .help("Share to \(profile.name)")
                    }
                }
            }
            .navigationTitle("Add to Talaria")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .help("Discard the shared item")
                }
            }
        }
    }

    private func row(for profile: ServerProfile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: profile.kind == .local ? "desktopcomputer" : "server.rack")
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.headline)
                Text(subtitle(for: profile))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
    }

    private func subtitle(for profile: ServerProfile) -> String {
        switch profile.kind {
        case .local: return "On this device"
        case .ssh: return profile.host ?? "Remote"
        }
    }
}

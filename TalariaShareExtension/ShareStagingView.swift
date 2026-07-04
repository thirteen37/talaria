import Observation
import SwiftUI

/// Progress/result state for the Share Extension's tiny staging UI. Owned by
/// `ShareViewController`, mutated on the main actor as staging proceeds.
@MainActor
@Observable
final class ShareStagingState {
    enum Status: Equatable {
        case working
        case success
        case failed(String)
    }

    var status: Status = .working
}

/// Minimal "Adding to Talaria…" sheet the Share Extension shows while it stages
/// the shared text/images into the App Group container and hands off to the host
/// app. Deliberately has no profile/session picker — that choice happens in the
/// host app after hand-off (see docs/architecture.md).
struct ShareStagingView: View {
    let state: ShareStagingState

    var body: some View {
        VStack(spacing: 16) {
            switch state.status {
            case .working:
                ProgressView()
                Text("Adding to Talaria…")
                    .font(.headline)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                Text("Added to Talaria")
                    .font(.headline)
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text("Couldn’t share to Talaria")
                    .font(.headline)
                // Dimmed `.primary`, not `.secondary`: `.secondary` renders
                // invisible over `.regularMaterial` on-device (vibrancy bug the
                // simulator can't reproduce).
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

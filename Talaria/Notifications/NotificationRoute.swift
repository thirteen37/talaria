import Foundation
import HermesKit

/// The destination a tapped notification resolves to: the profile window that
/// owns the chat, the chat's session id, and a best-effort title for any UI
/// that wants to label the focus action. Published by ``ChatNotifier`` when the
/// user taps a banner; consumed by the window scene to open/focus the window
/// and select the session.
struct NotificationRoute: Equatable, Sendable {
    let profileId: UUID
    let sessionId: SessionId
    let title: String?
}

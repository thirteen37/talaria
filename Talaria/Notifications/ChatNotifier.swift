import Foundation
import HermesKit
import UserNotifications

/// App-wide bridge to `UNUserNotificationCenter`: requests authorization, posts
/// the two chat notifications, and turns a tapped banner into a
/// ``NotificationRoute`` the window scene observes. One shared instance
/// (`ChatNotifier.shared`) so the launch delegate, every window's store, and
/// the Settings screen all talk to the same center delegate.
///
/// Cross-platform: `UNUserNotificationCenter` is the same API on macOS and iOS,
/// so this lives in the shared tree (no `macOS/`/`iOS/` seam). The framework is
/// auto-linked on `import`; local notifications need no entitlement.
@MainActor
@Observable
final class ChatNotifier: NSObject {
    static let shared = ChatNotifier()

    /// The app-wide notification preferences. Owned here so there's a single
    /// source of truth shared by the per-window stores' policy checks and the
    /// Settings UI (which the app injects this same instance into).
    let settings = NotificationSettings()

    /// Set when the user taps a notification; the window scene reacts by
    /// focusing the profile window and selecting the session, then clears it.
    var pendingRoute: NotificationRoute?

    /// `userInfo` keys carried on every notification so a tap can be routed back
    /// to the originating window + session.
    private enum UserInfoKey {
        static let profileId = "profileId"
        static let sessionId = "sessionId"
        static let title = "title"
    }

    private var didRequestAuthorization = false

    private override init() {
        super.init()
    }

    /// Requests `.alert` + `.sound` authorization once, the first time the user
    /// turns the master toggle on. Repeated calls are cheap no-ops after the
    /// first (the system also remembers the decision across launches).
    func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                // `Logger` is thread-safe, so no actor hop is needed (and capturing
                // the non-Sendable `error` into one would be a concurrency error).
                AppLog.general.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Posts the "agent finished a turn" banner for `sessionId` in `profileId`'s
    /// window. `title` is the chat's display name (falls back to "Chat").
    func postAgentFinished(profileId: UUID, sessionId: SessionId, title: String?) {
        let chat = displayTitle(title)
        post(
            profileId: profileId,
            sessionId: sessionId,
            title: chat,
            body: "Agent finished responding.",
            displayTitle: title
        )
    }

    /// Posts the "tool needs approval" banner for `sessionId` in `profileId`'s
    /// window. `toolName` names the blocked tool when known.
    func postToolApproval(profileId: UUID, sessionId: SessionId, title: String?, toolName: String?) {
        let chat = displayTitle(title)
        let body = toolName.map { "“\($0)” needs your approval." } ?? "A tool needs your approval."
        post(
            profileId: profileId,
            sessionId: sessionId,
            title: chat,
            body: body,
            displayTitle: title
        )
    }

    // MARK: - Delivery

    private func post(
        profileId: UUID,
        sessionId: SessionId,
        title: String,
        body: String,
        displayTitle: String?
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // Group every banner for one chat into a single thread.
        content.threadIdentifier = sessionId
        content.userInfo = [
            UserInfoKey.profileId: profileId.uuidString,
            UserInfoKey.sessionId: sessionId,
            UserInfoKey.title: displayTitle ?? "",
        ]
        // Unique id per delivery; nil trigger fires immediately.
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func displayTitle(_ title: String?) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Chat" : trimmed
    }

    /// Decodes a notification's `userInfo` into a route. `nonisolated static`
    /// (pure) so the delegate callback can run it off the main actor and hand
    /// only the `Sendable` ``NotificationRoute`` across the actor hop — the raw
    /// `UN*` objects aren't `Sendable`.
    private nonisolated static func route(from userInfo: [AnyHashable: Any]) -> NotificationRoute? {
        guard let profileString = userInfo[UserInfoKey.profileId] as? String,
              let profileId = UUID(uuidString: profileString),
              let sessionId = userInfo[UserInfoKey.sessionId] as? String else {
            return nil
        }
        let title = userInfo[UserInfoKey.title] as? String
        return NotificationRoute(
            profileId: profileId,
            sessionId: sessionId,
            title: (title?.isEmpty == true) ? nil : title
        )
    }
}

extension ChatNotifier: UNUserNotificationCenterDelegate {
    /// A tapped banner decodes to a route the window scene consumes. `nonisolated`
    /// because the non-`Sendable` `UN*` parameters can't cross into a
    /// main-actor-isolated method; we decode the `Sendable` route here and hop.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let route = Self.route(from: response.notification.request.content.userInfo)
        await MainActor.run { [weak self] in
            self?.pendingRoute = route
        }
    }

    /// Present the banner even while the app is active. The per-session decision
    /// was already made at the trigger site (`NotificationPolicy` suppresses only
    /// when this window is foreground *and* this session is selected), so any
    /// notification that reaches delivery is one the user should see — typically
    /// because they're working in a different tab or window. Suppressing here on
    /// whole-app foreground would defeat that per-session gating.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

import Foundation

/// Pure, no-UI decision functions for whether a notification should fire. Kept
/// separate from ``ChatNotifier`` (which touches `UNUserNotificationCenter`) so
/// the gating logic is unit-testable without the notification framework.
///
/// The shared rule for both events: notify iff the master toggle **and** the
/// event's sub-toggle are on, **and** the user is not actively watching that
/// chat (its window foreground *and* that session selected ⇒ suppress).
///
/// `@MainActor` only because it reads `NotificationSettings` (a `@MainActor`
/// observable); the logic itself is pure.
@MainActor
enum NotificationPolicy {
    static func shouldNotifyAgentFinished(
        settings: NotificationSettings,
        isForeground: Bool,
        isSelected: Bool
    ) -> Bool {
        guard settings.notificationsEnabled, settings.notifyAgentFinished else {
            return false
        }
        return !(isForeground && isSelected)
    }

    static func shouldNotifyToolApproval(
        settings: NotificationSettings,
        isForeground: Bool,
        isSelected: Bool
    ) -> Bool {
        guard settings.notificationsEnabled, settings.notifyToolApproval else {
            return false
        }
        return !(isForeground && isSelected)
    }
}

import Foundation
import SwiftUI

/// How often the app runs a background `hermes update --check`. Backs the
/// interval picker on the Notifications settings tab; the raw `String` is what
/// ``NotificationSettings`` persists.
enum UpdateCheckInterval: String, CaseIterable, Sendable {
    case sixHours
    case daily
    case weekly

    /// Sleep between background checks.
    var duration: Duration {
        switch self {
        case .sixHours: return .seconds(6 * 3600)
        case .daily: return .seconds(86_400)
        case .weekly: return .seconds(604_800)
        }
    }

    /// Picker label.
    var label: String {
        switch self {
        case .sixHours: return "Every 6 hours"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        }
    }
}

/// Global, `UserDefaults`-backed preferences for OS-level chat notifications,
/// mirroring ``SidebarLayout``: one set of toggles for the whole app, shared by
/// every window and the Settings screen. A master switch gates two independent
/// sub-toggles (agent-finished and tool-approval). `UserDefaults` is injectable
/// so tests can round-trip against an isolated suite.
///
/// The booleans default to `false` (off) — the first time the user flips the
/// master on, the Settings UI asks ``ChatNotifier`` to request OS authorization.
@MainActor
@Observable
final class NotificationSettings {
    private static let enabledKey = "notificationsEnabled"
    private static let agentFinishedKey = "notifyAgentFinished"
    private static let toolApprovalKey = "notifyToolApproval"
    private static let checkForUpdatesKey = "checkForUpdatesInBackground"
    private static let updateIntervalKey = "updateCheckInterval"

    /// Master switch. With this off, nothing notifies regardless of the
    /// sub-toggles.
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Self.enabledKey) }
    }

    /// Notify when a turn the user started finishes.
    var notifyAgentFinished: Bool {
        didSet { defaults.set(notifyAgentFinished, forKey: Self.agentFinishedKey) }
    }

    /// Notify when a tool needs the user's approval.
    var notifyToolApproval: Bool {
        didSet { defaults.set(notifyToolApproval, forKey: Self.toolApprovalKey) }
    }

    /// Run `hermes update --check` periodically in the background and post an OS
    /// notification when an update becomes available. Independent of the master
    /// chat-notifications toggle. Defaults off so the app never asks for OS
    /// authorization until the user opts in.
    var checkForUpdatesInBackground: Bool {
        didSet { defaults.set(checkForUpdatesInBackground, forKey: Self.checkForUpdatesKey) }
    }

    /// How often the background update check runs.
    var updateCheckInterval: UpdateCheckInterval {
        didSet { defaults.set(updateCheckInterval.rawValue, forKey: Self.updateIntervalKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Sub-toggles default on so enabling the master immediately notifies for
        // both events (the common case); the master itself defaults off so the
        // app never asks for OS authorization until the user opts in.
        self.notificationsEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
        self.notifyAgentFinished = defaults.object(forKey: Self.agentFinishedKey) as? Bool ?? true
        self.notifyToolApproval = defaults.object(forKey: Self.toolApprovalKey) as? Bool ?? true
        // Background update checks default off (same authorization-gating
        // reasoning as the master toggle); interval defaults to daily.
        self.checkForUpdatesInBackground = defaults.object(forKey: Self.checkForUpdatesKey) as? Bool ?? false
        self.updateCheckInterval = (defaults.string(forKey: Self.updateIntervalKey))
            .flatMap(UpdateCheckInterval.init(rawValue:)) ?? .daily
    }
}

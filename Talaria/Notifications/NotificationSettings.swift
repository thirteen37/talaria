import Foundation
import SwiftUI

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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Sub-toggles default on so enabling the master immediately notifies for
        // both events (the common case); the master itself defaults off so the
        // app never asks for OS authorization until the user opts in.
        self.notificationsEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
        self.notifyAgentFinished = defaults.object(forKey: Self.agentFinishedKey) as? Bool ?? true
        self.notifyToolApproval = defaults.object(forKey: Self.toolApprovalKey) as? Bool ?? true
    }
}

import Foundation
import Testing
@testable import Talaria

@MainActor
@Suite
struct NotificationPolicyTests {
    private func makeSettings(
        enabled: Bool = true,
        agentFinished: Bool = true,
        toolApproval: Bool = true,
        _ name: String = #function
    ) -> NotificationSettings {
        let suite = "NotificationPolicyTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = NotificationSettings(defaults: defaults)
        settings.notificationsEnabled = enabled
        settings.notifyAgentFinished = agentFinished
        settings.notifyToolApproval = toolApproval
        return settings
    }

    // MARK: - Master toggle

    @Test
    func masterOffSuppressesBothEvents() {
        let settings = makeSettings(enabled: false)
        #expect(!NotificationPolicy.shouldNotifyAgentFinished(settings: settings, isForeground: false, isSelected: false))
        #expect(!NotificationPolicy.shouldNotifyToolApproval(settings: settings, isForeground: false, isSelected: false))
    }

    // MARK: - Sub-toggles

    @Test
    func agentFinishedSubToggleOffSuppressesOnlyThatEvent() {
        let settings = makeSettings(agentFinished: false, toolApproval: true)
        #expect(!NotificationPolicy.shouldNotifyAgentFinished(settings: settings, isForeground: false, isSelected: false))
        // The other event still fires.
        #expect(NotificationPolicy.shouldNotifyToolApproval(settings: settings, isForeground: false, isSelected: false))
    }

    @Test
    func toolApprovalSubToggleOffSuppressesOnlyThatEvent() {
        let settings = makeSettings(agentFinished: true, toolApproval: false)
        #expect(!NotificationPolicy.shouldNotifyToolApproval(settings: settings, isForeground: false, isSelected: false))
        #expect(NotificationPolicy.shouldNotifyAgentFinished(settings: settings, isForeground: false, isSelected: false))
    }

    // MARK: - Foreground / selection gating

    @Test
    func foregroundAndSelectedSuppressesBothEvents() {
        let settings = makeSettings()
        #expect(!NotificationPolicy.shouldNotifyAgentFinished(settings: settings, isForeground: true, isSelected: true))
        #expect(!NotificationPolicy.shouldNotifyToolApproval(settings: settings, isForeground: true, isSelected: true))
    }

    @Test
    func backgroundButSelectedStillNotifies() {
        let settings = makeSettings()
        #expect(NotificationPolicy.shouldNotifyAgentFinished(settings: settings, isForeground: false, isSelected: true))
        #expect(NotificationPolicy.shouldNotifyToolApproval(settings: settings, isForeground: false, isSelected: true))
    }

    @Test
    func foregroundButDifferentSessionStillNotifies() {
        let settings = makeSettings()
        #expect(NotificationPolicy.shouldNotifyAgentFinished(settings: settings, isForeground: true, isSelected: false))
        #expect(NotificationPolicy.shouldNotifyToolApproval(settings: settings, isForeground: true, isSelected: false))
    }
}

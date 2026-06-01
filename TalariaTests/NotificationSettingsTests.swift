import Foundation
import Testing
@testable import Talaria

@MainActor
@Suite
struct NotificationSettingsTests {
    /// A throwaway `UserDefaults` suite so each test gets isolated, clean
    /// storage that never touches the real app domain.
    private func makeDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "NotificationSettingsTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test
    func defaultsMasterOffSubTogglesOn() {
        let settings = NotificationSettings(defaults: makeDefaults())

        // Master defaults off so the app never asks for OS authorization until
        // the user opts in; both sub-toggles default on.
        #expect(!settings.notificationsEnabled)
        #expect(settings.notifyAgentFinished)
        #expect(settings.notifyToolApproval)
    }

    @Test
    func mutationsRoundTripThroughDefaults() {
        let defaults = makeDefaults()
        let settings = NotificationSettings(defaults: defaults)

        settings.notificationsEnabled = true
        settings.notifyAgentFinished = false
        settings.notifyToolApproval = false

        // A fresh store reading the same defaults sees the persisted values.
        let reloaded = NotificationSettings(defaults: defaults)
        #expect(reloaded.notificationsEnabled)
        #expect(!reloaded.notifyAgentFinished)
        #expect(!reloaded.notifyToolApproval)
    }

    @Test
    func reEnablingASubToggleRoundTrips() {
        let defaults = makeDefaults()
        let settings = NotificationSettings(defaults: defaults)

        settings.notifyAgentFinished = false
        #expect(!NotificationSettings(defaults: defaults).notifyAgentFinished)

        settings.notifyAgentFinished = true
        #expect(NotificationSettings(defaults: defaults).notifyAgentFinished)
    }
}

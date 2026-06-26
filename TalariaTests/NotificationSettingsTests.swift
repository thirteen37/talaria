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
        // Background update checks default off; interval defaults to daily.
        #expect(!settings.checkForUpdatesInBackground)
        #expect(settings.updateCheckInterval == .daily)
    }

    @Test
    func mutationsRoundTripThroughDefaults() {
        let defaults = makeDefaults()
        let settings = NotificationSettings(defaults: defaults)

        settings.notificationsEnabled = true
        settings.notifyAgentFinished = false
        settings.notifyToolApproval = false
        settings.checkForUpdatesInBackground = true
        settings.updateCheckInterval = .weekly

        // A fresh store reading the same defaults sees the persisted values.
        let reloaded = NotificationSettings(defaults: defaults)
        #expect(reloaded.notificationsEnabled)
        #expect(!reloaded.notifyAgentFinished)
        #expect(!reloaded.notifyToolApproval)
        #expect(reloaded.checkForUpdatesInBackground)
        #expect(reloaded.updateCheckInterval == .weekly)
    }

    @Test
    func updateCheckIntervalDurationsAndLabels() {
        #expect(UpdateCheckInterval.sixHours.duration == .seconds(6 * 3600))
        #expect(UpdateCheckInterval.daily.duration == .seconds(86_400))
        #expect(UpdateCheckInterval.weekly.duration == .seconds(604_800))

        #expect(UpdateCheckInterval.sixHours.label == "Every 6 hours")
        #expect(UpdateCheckInterval.daily.label == "Daily")
        #expect(UpdateCheckInterval.weekly.label == "Weekly")

        // Every case is offered to the picker.
        #expect(UpdateCheckInterval.allCases.count == 3)
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

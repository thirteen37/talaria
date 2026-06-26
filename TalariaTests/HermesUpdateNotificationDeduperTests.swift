import Foundation
import Testing
@testable import Talaria

/// The cross-window de-dupe gate that stops multiple windows open on the same
/// profile from each posting a banner for the same Hermes update.
///
/// `shouldNotify`/`clear` are `mutating`, which can't be called inside the
/// `#expect` macro (it captures the expression as an immutable value), so each
/// result is bound first.
@Suite
struct HermesUpdateNotificationDeduperTests {
    @Test
    func firstNotifyForProfileIsAllowedThenSuppressed() {
        var deduper = HermesUpdateNotificationDeduper()
        let profile = UUID()

        // The window that checks first notifies; a second window passing the same
        // token (the cross-window dup) is suppressed.
        let first = deduper.shouldNotify(profileId: profile, token: "1.3.0")
        let second = deduper.shouldNotify(profileId: profile, token: "1.3.0")
        #expect(first)
        #expect(!second)
    }

    @Test
    func differentTokenNotifiesAgain() {
        var deduper = HermesUpdateNotificationDeduper()
        let profile = UUID()

        let first = deduper.shouldNotify(profileId: profile, token: "1.3.0")
        // A newer version is a distinct update.
        let newer = deduper.shouldNotify(profileId: profile, token: "1.4.0")
        #expect(first)
        #expect(newer)
    }

    @Test
    func clearAllowsTheSameTokenToNotifyAgain() {
        var deduper = HermesUpdateNotificationDeduper()
        let profile = UUID()

        let first = deduper.shouldNotify(profileId: profile, token: "source-available")
        let dup = deduper.shouldNotify(profileId: profile, token: "source-available")
        #expect(first)
        #expect(!dup)

        // After the user applies (a check reported up to date), the same sentinel
        // token must be able to notify again for the next source update.
        deduper.clear(profileId: profile)
        let afterClear = deduper.shouldNotify(profileId: profile, token: "source-available")
        #expect(afterClear)
    }

    @Test
    func profilesAreIndependent() {
        var deduper = HermesUpdateNotificationDeduper()
        let a = UUID()
        let b = UUID()

        let notifyA = deduper.shouldNotify(profileId: a, token: "1.3.0")
        // A different server's identical version is a separate notification.
        let notifyB = deduper.shouldNotify(profileId: b, token: "1.3.0")
        #expect(notifyA)
        #expect(notifyB)

        // Clearing one leaves the other's record intact.
        deduper.clear(profileId: a)
        let bStillSuppressed = deduper.shouldNotify(profileId: b, token: "1.3.0")
        #expect(!bStillSuppressed)
    }
}

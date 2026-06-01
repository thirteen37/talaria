import UIKit
import UserNotifications

/// iOS application delegate, wired via `@UIApplicationDelegateAdaptor` in the
/// iOS `TalariaApp`. Mirror of the macOS launch delegate: installs
/// ``ChatNotifier/shared`` as the `UNUserNotificationCenter` delegate at launch
/// so a tap that cold-launches the app is captured. Same `TalariaLaunchDelegate`
/// symbol as the macOS half — the folder excludes compile only one per target.
final class TalariaLaunchDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = ChatNotifier.shared
        return true
    }
}

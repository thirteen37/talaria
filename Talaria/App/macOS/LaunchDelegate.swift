import AppKit
import UserNotifications

/// macOS application delegate, wired via `@NSApplicationDelegateAdaptor` in
/// `TalariaApp`. Its one job is to install ``ChatNotifier/shared`` as the
/// `UNUserNotificationCenter` delegate at launch — Apple requires the delegate
/// be set before the app finishes launching so a tap that cold-launches the app
/// is delivered instead of dropped.
///
/// The iOS mirror (`App/iOS/LaunchDelegate.swift`) defines the same
/// `TalariaLaunchDelegate` symbol; the `**/macOS/**` / `**/iOS/**` folder
/// excludes in `project.yml` compile only one per target, so neither needs an
/// `#if`.
final class TalariaLaunchDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = ChatNotifier.shared
    }
}

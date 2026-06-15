import Foundation
import HermesKit

/// Launch-argument flags the UI test bundle passes to the app.
enum UITestFlags {
    /// Replaces the real server with the in-process ``MockChatBackend`` so the
    /// chat surface can be driven without a real dashboard.
    static var mockServer: Bool {
        arguments.contains("-uiTestMockServer")
    }

    /// Boots the app against deterministic, synthetic data for docs/marketing
    /// screenshots. This mode must not read a user's real profiles, sessions, or
    /// dashboard.
    static var screenshotFixture: Bool {
        arguments.contains("-screenshotFixture")
    }

    /// Optional screenshot entry point. Supported values:
    /// `chat`, or any ``BrowseDestination.rawValue`` such as `sessions`,
    /// `extensions`, `models`, and `cron`.
    static var screenshotSurface: String? {
        value(after: "-screenshotSurface")
    }

    static var screenshotBrowseDestination: BrowseDestination? {
        guard let screenshotSurface else { return .sessions }
        if screenshotSurface == "chat" || screenshotSurface.hasPrefix("chat-") { return nil }
        return BrowseDestination(rawValue: screenshotSurface) ?? .sessions
    }

    static var opensScreenshotChat: Bool {
        guard let screenshotSurface else { return false }
        return screenshotSurface == "chat" || screenshotSurface.hasPrefix("chat-")
    }

    /// For the `chat-clarify` / `chat-approval` / `chat-secret` screenshot
    /// surfaces, the blocking-prompt kind to inject into the open chat so its
    /// rendering can be captured. `nil` for every other surface.
    static var screenshotPromptKind: UserPromptKind? {
        switch screenshotSurface {
        case "chat-clarify": .question
        case "chat-approval": .permission
        case "chat-secret": .secret
        default: nil
        }
    }

    private static var arguments: [String] {
        ProcessInfo.processInfo.arguments
    }

    private static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        return arguments[valueIndex]
    }
}

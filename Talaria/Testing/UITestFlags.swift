import Foundation

/// Launch-argument flags the UI test bundle passes to the app.
enum UITestFlags {
    /// Replaces the real server with the in-process ``MockChatBackend`` so the
    /// chat surface can be driven without a real dashboard.
    static var mockServer: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestMockServer")
    }
}

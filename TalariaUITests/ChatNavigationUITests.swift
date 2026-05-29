import XCTest

/// Drives the iPhone chat flow against the in-process mock ACP server
/// (`-uiTestMockServer`). These verify the navigation that's been hard to
/// observe on-device: tapping "New session" must push the chat view.
final class ChatNavigationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestMockServer"]
        app.launch()
        return app
    }

    /// The sidebar root should show the Chat section + New session button.
    func testSidebarShowsNewSession() {
        let app = launchApp()
        XCTAssertTrue(
            app.buttons["New session"].waitForExistence(timeout: 10),
            "Expected the New session button on the sidebar root"
        )
    }

    /// Tapping New session must open the chat: the composer text field
    /// ("Message Hermes") should appear. This is the navigation that was
    /// silently failing on iPhone.
    func testNewSessionPushesChat() {
        let app = launchApp()
        let newSession = app.buttons["New session"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 10))
        newSession.tap()

        // The composer placeholder lives in ChatView. Its presence proves the
        // chat pushed into view.
        let composer = app.textFields["Message Hermes"]
        XCTAssertTrue(
            composer.waitForExistence(timeout: 10),
            "Chat composer did not appear after tapping New session — navigation to ChatView failed"
        )
    }

    /// The log console (ladybug) opens and shows the Logs view.
    func testLogConsoleOpens() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["New session"].waitForExistence(timeout: 10))
        app.buttons["Logs"].tap()
        XCTAssertTrue(
            app.navigationBars["Logs"].waitForExistence(timeout: 5),
            "Log console sheet did not appear"
        )
    }

    /// End-to-end: send a prompt and see the mock agent's reply render.
    func testSendPromptShowsAgentReply() {
        let app = launchApp()
        let newSession = app.buttons["New session"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 10))
        newSession.tap()

        let composer = app.textFields["Message Hermes"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("ping")
        // Send button (paperplane) — fall back to the keyboard return if needed.
        if app.buttons["Send"].exists {
            app.buttons["Send"].tap()
        } else {
            app.typeText("\n")
        }

        XCTAssertTrue(
            app.staticTexts["Hello from the mock Hermes server."].waitForExistence(timeout: 10),
            "Expected the mock agent reply to render in the transcript"
        )
    }
}

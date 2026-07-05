import XCTest

/// Reproduction harness for the iOS "crash on first character typed" report.
/// Drives the composer against the in-process mock backend with the slash
/// catalog populated (`-uiTestMockCommands`, mirroring a real remote), then
/// types into the field. A crash fails the test with the captured backtrace.
final class ComposerInputCrashUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launchAppWithCommands() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestMockServer", "-uiTestMockCommands"]
        app.launch()
        return app
    }

    private func openComposer(_ app: XCUIApplication) -> XCUIElement {
        let newSession = app.buttons["New session"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 15))
        newSession.tap()
        let composer = app.textFields["Message Hermes"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15), "Composer did not appear")
        return composer
    }

    /// The core reproduction: with the slash catalog populated, type a single
    /// NON-slash character. The keystroke is the first hardware-key event, which
    /// makes UIKit rebuild the main menu from the responder chain — the point
    /// where the duplicate ⌃⌘S command used to abort the app. Uses app-level
    /// `typeText` (into the focused composer) so the assertion survives the
    /// field's placeholder-identifier changing once text is present.
    func testTypeFirstNonSlashCharacter() {
        let app = launchAppWithCommands()
        openComposer(app).tap()
        app.typeText("a")
        XCTAssertEqual(app.state, .runningForeground, "App crashed after first character")
    }

    /// Exercises the slash path too: type "/", then a letter.
    func testTypeSlashThenLetter() {
        let app = launchAppWithCommands()
        openComposer(app).tap()
        app.typeText("/")
        XCTAssertEqual(app.state, .runningForeground, "App crashed after '/'")
        app.typeText("h")
        XCTAssertEqual(app.state, .runningForeground, "App crashed after '/h'")
    }
}

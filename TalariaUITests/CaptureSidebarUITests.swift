import XCTest

final class CaptureSidebarUITests: XCTestCase {
    func testCaptureSidebarRow() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestMockServer"]
        app.launch()
        let newSession = app.buttons["New session"]
        _ = newSession.waitForExistence(timeout: 10)
        newSession.tap()
        _ = app.textFields["Message Hermes"].waitForExistence(timeout: 10)
        // Go back to the sidebar so the session row is visible.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        _ = app.buttons["New session"].waitForExistence(timeout: 10)
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "sidebar-row"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

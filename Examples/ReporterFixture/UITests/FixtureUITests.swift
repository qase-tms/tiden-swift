import XCTest

@MainActor
final class FixtureUITests: XCTestCase {
    func testScreenshotAttachment() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture-label"].waitForExistence(timeout: 10))
        #if os(macOS)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: window.screenshot())
        #else
        let attachment = XCTAttachment(screenshot: app.screenshot())
        #endif
        attachment.name = "Reporter fixture screenshot"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

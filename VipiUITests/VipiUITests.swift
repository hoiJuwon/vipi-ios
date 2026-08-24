import XCTest

final class VipiUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    func testOpenSessionAndSendPrompt() {
        let session = app.buttons["session.mobile"]
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("UI test prompt")
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
    }

    func testPairingAndConnectionControlsAreAccessible() {
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.secureTextFields["settings.pairingPayload"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["settings.host"].exists)
        XCTAssertTrue(app.secureTextFields["settings.token"].exists)
        XCTAssertTrue(app.buttons["settings.connect"].exists)
        XCTAssertTrue(app.buttons["settings.rotateToken"].exists)
    }
}

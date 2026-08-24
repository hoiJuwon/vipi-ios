import Foundation
import XCTest

final class VipiUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        if name.contains("LiveHost") {
            app.launchEnvironment["VIPI_E2E_PAIRING"] = #"{"host":"http://127.0.0.1:9876","token":"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"}"#
        }
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

    func testLiveHostPairingHistoryStreamingToolsAndAbort() throws {
        let healthURL = URL(string: "http://127.0.0.1:9876/health")!
        guard (try? Data(contentsOf: healthURL)) != nil else {
            throw XCTSkip("Start the documented local E2E fixture on port 9876")
        }
        app.tabBars.buttons["Settings"].tap()
        app.buttons["settings.connect"].tap()

        app.tabBars.buttons["Sessions"].tap()
        let session = app.buttons["session.e2e"]
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        session.tap()
        XCTAssertTrue(app.staticTexts["History restored"].waitForExistence(timeout: 10))

        let composer = app.textFields["chat.composer"]
        composer.tap()
        composer.typeText("Live prompt")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.staticTexts["Streaming complete"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["read completed"].waitForExistence(timeout: 5))
        app.buttons["chat.menu"].tap()
        let abort = app.buttons["chat.abort"]
        XCTAssertTrue(abort.waitForExistence(timeout: 3))
        abort.tap()
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

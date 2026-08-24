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
        XCTAssertEqual(session.label, "개발 / 모바일 세션 앱")
        XCTAssertTrue((session.value as? String)?.contains("현재 앱 셸과 연결 프로토콜") == true)
        XCTAssertTrue(session.isHittable)
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
            XCTFail("The canonical test runner must provision the local E2E fixture on port 9876")
            return
        }
        app.tabBars.buttons["Settings"].tap()
        app.buttons["settings.connect"].tap()

        app.tabBars.buttons["Sessions"].tap()
        let session = app.buttons["session.e2e"]
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        session.tap()
        XCTAssertTrue(app.staticTexts["History restored"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["chat.previousPiMessage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chat.latestPiMessage"].exists)

        let composer = app.textFields["chat.composer"]
        composer.tap()
        composer.typeText("Live prompt")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.staticTexts["Streaming complete"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["read completed"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements.matching(
            NSPredicate(format: "label == %@", "Session status")
        ).firstMatch.exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertTrue(composer.isHittable)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Streaming complete")).count, 1)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Tool read")).count, 1)
        app.buttons["chat.menu"].tap()
        let abort = app.buttons["chat.abort"]
        XCTAssertTrue(abort.waitForExistence(timeout: 3))
        abort.tap()
    }

    func testVoiceOverSemanticsAndNavigation() {
        let connection = app.otherElements["connection.status"].firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 5))
        XCTAssertEqual(connection.label, "Connection")
        XCTAssertFalse((connection.value as? String ?? "").isEmpty)

        let session = app.buttons["session.mobile"]
        XCTAssertTrue(scrollToHittable(session))
        session.tap()
        let transcript = app.scrollViews["chat.transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        let composer = app.textFields["chat.composer"]
        XCTAssertEqual(composer.label, "Message Pi")
        XCTAssertTrue(composer.isHittable)
        let send = app.buttons["chat.send"]
        XCTAssertEqual(send.label, "Send message")
        XCTAssertFalse(send.isEnabled)
        let tool = app.buttons.matching(NSPredicate(format: "label == %@", "Tool read")).firstMatch
        for _ in 0..<8 where !tool.exists { transcript.swipeUp() }
        XCTAssertTrue(tool.waitForExistence(timeout: 5))
        XCTAssertTrue((tool.value as? String)?.contains("succeeded") == true)
        XCTAssertTrue(app.buttons["chat.menu"].isHittable)
    }

    func testPairingAndConnectionControlsAreAccessible() {
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.secureTextFields["settings.pairingPayload"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollToExistence(app.textFields["settings.host"]))
        XCTAssertTrue(scrollToExistence(app.secureTextFields["settings.token"]))
        let connect = app.buttons["settings.connect"]
        XCTAssertTrue(scrollToExistence(connect))
        XCTAssertEqual(connect.label, "Connect securely")
        XCTAssertTrue(connect.isHittable)
        let rotate = app.buttons["settings.rotateToken"]
        XCTAssertTrue(scrollToExistence(rotate))
        XCTAssertEqual(rotate.label, "Rotate device token")
        XCTAssertFalse(rotate.isEnabled)
    }

    private func scrollToHittable(_ element: XCUIElement) -> Bool {
        for _ in 0..<10 {
            if element.isHittable { return true }
            app.swipeUp()
        }
        return element.isHittable
    }

    private func scrollToExistence(_ element: XCUIElement) -> Bool {
        for _ in 0..<6 {
            if element.exists { return true }
            app.swipeUp()
        }
        return element.exists
    }
}

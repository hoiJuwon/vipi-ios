import Foundation
import XCTest

final class VipiUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        if name.contains("PermissionInteraction") {
            app.launchArguments += ["--interaction-preview", "--chat-preview"]
        }
        if name.contains("SplashPreview") {
            app.launchArguments += ["--splash-preview"]
        }
        if name.contains("MarkdownTable") {
            app.launchArguments += ["--chat-preview", "--markdown-table-preview"]
        }
        if name.contains("LiveHost") {
            app.launchEnvironment["VIPI_E2E_PAIRING"] = #"{"host":"http://127.0.0.1:9876","token":"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"}"#
        }
        if name.contains("NotificationTap") {
            app.launchArguments += ["--notification-session", "mobile"]
        }
        app.launch()
    }

    func testNotificationTapRoutesToRequestedSessionOnColdLaunch() {
        XCTAssertTrue(app.navigationBars["모바일 세션 앱"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["chat.composer"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.alerts["Command failed"].exists)
    }

    func testSplashPreviewShowsCodeWordmark() {
        let splash = app.otherElements["splash.view"]
        XCTAssertTrue(splash.waitForExistence(timeout: 5))
        XCTAssertEqual(splash.label, "vipi")
        XCTAssertFalse(app.navigationBars.firstMatch.isHittable)
    }

    func testMarkdownTableRendersAsCellsInsteadOfRawPipes() {
        let firstHeader = app.textViews["판타지 군"]
        XCTAssertTrue(firstHeader.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["예시 관계·상황"].exists)
        XCTAssertTrue(app.textViews["10"].firstMatch.exists)
        XCTAssertFalse(app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "|---|")).firstMatch.exists)
    }

    func testNewSessionPickerShowsRegisteredWorkspacesAndCreatesSession() {
        let search = app.textFields["sessions.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let add = app.buttons["sessions.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertTrue(add.isHittable)
        XCTAssertGreaterThan(add.frame.minY, app.frame.midY)
        XCTAssertTrue(app.buttons["sessions.settings"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        add.tap()

        XCTAssertTrue(app.navigationBars["New Session"].waitForExistence(timeout: 5))
        let workspace = app.buttons["workspace.registered./Users/choijuwon/vipi-ios"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        workspace.tap()

        let create = app.buttons["session.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertTrue(create.isEnabled)
        create.tap()

        XCTAssertFalse(app.navigationBars["New Session"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["기타 / 새 세션"].waitForExistence(timeout: 5))
    }

    func testProviderSelectorSwitchesWithoutChangingPiSessions() {
        let selector = app.buttons["connection.status"]
        XCTAssertTrue(selector.waitForExistence(timeout: 5))
        XCTAssertTrue(selector.isHittable)
        selector.tap()

        let codex = app.buttons["provider.codex"]
        XCTAssertTrue(codex.waitForExistence(timeout: 3))
        codex.tap()
        XCTAssertTrue(app.staticTexts["No Codex sessions"].waitForExistence(timeout: 3))

        app.buttons["connection.status"].tap()
        let pi = app.buttons["provider.pi"]
        XCTAssertTrue(pi.waitForExistence(timeout: 3))
        pi.tap()
        XCTAssertTrue(app.buttons["session.mobile"].waitForExistence(timeout: 3))
    }

    func testOpenSessionAndSendPrompt() {
        XCTAssertFalse(app.tabBars.buttons["Activity"].exists)
        let session = app.buttons["session.mobile"]
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        XCTAssertEqual(session.label, "개발 / 모바일 세션 앱")
        XCTAssertTrue((session.value as? String)?.contains("현재 앱 셸과 연결 프로토콜") == true)
        XCTAssertTrue(session.isHittable)
        session.tap()

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chat.stop"].isEnabled)
        composer.tap()
        composer.typeText("UI test prompt")
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        XCTAssertTrue(send.isEnabled)
        XCTAssertFalse(app.buttons["chat.stop"].exists)
        send.tap()
        let queue = app.descendants(matching: .any)["chat.queue"]
        XCTAssertTrue(queue.waitForExistence(timeout: 3))
        XCTAssertEqual(queue.value as? String, "1")
        let progress = app.descendants(matching: .any)["chat.progress"]
        XCTAssertTrue(progress.exists)
        XCTAssertTrue((progress.value as? String)?.contains("m") == true)
        XCTAssertTrue((progress.value as? String)?.contains("s") == true)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "작업 기록")).count, 0)
    }

    func testComposerAddMenuInsertsGoalCommand() {
        let session = app.buttons["session.hello"]
        XCTAssertTrue(scrollToHittable(session))
        session.tap()

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let add = app.buttons["chat.add"]
        XCTAssertTrue(add.isHittable)
        XCTAssertGreaterThanOrEqual(add.frame.minY, composer.frame.maxY)
        XCTAssertLessThan(composer.frame.minX, add.frame.maxX)
        XCTAssertGreaterThanOrEqual(add.frame.width, 44)
        XCTAssertGreaterThanOrEqual(add.frame.height, 44)
        add.tap()
        let goal = app.buttons["Goal"]
        XCTAssertTrue(goal.waitForExistence(timeout: 3))
        goal.tap()
        XCTAssertTrue((composer.value as? String)?.hasPrefix("/goal") == true)
    }

    func testSubmittedPromptMovesToTopOfResponseViewport() {
        let session = app.buttons["session.hello"]
        XCTAssertTrue(scrollToHittable(session))
        session.tap()

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Keep this prompt at the top")
        app.buttons["chat.send"].tap()

        let submittedPrompt = app.staticTexts["Keep this prompt at the top"]
        XCTAssertTrue(submittedPrompt.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertLessThan(submittedPrompt.frame.minY, app.navigationBars.firstMatch.frame.maxY + 44)
        XCTAssertTrue(app.descendants(matching: .any)["chat.progress"].exists)
    }

    func testSelectedAssistantTextCanBeAddedToComposer() {
        let session = app.buttons["session.mobile"]
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()

        app.buttons["chat.previousAssistantMessage"].tap()
        Thread.sleep(forTimeInterval: 0.7)
        app.buttons["chat.nextAssistantMessage"].tap()
        Thread.sleep(forTimeInterval: 0.7)

        let selectableText = app.textViews.matching(NSPredicate(format: "label == %@", "작업 흐름")).firstMatch
        XCTAssertTrue(selectableText.waitForExistence(timeout: 5))
        selectableText.press(forDuration: 1.2)
        let addToChat = app.menuItems["Add to Chat"]
        XCTAssertTrue(addToChat.waitForExistence(timeout: 3))
        addToChat.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.annotation"].waitForExistence(timeout: 3))
    }

    func testLiveHostPairingHistoryStreamingToolsAndAbort() throws {
        let healthURL = URL(string: "http://127.0.0.1:9876/health")!
        guard (try? Data(contentsOf: healthURL)) != nil else {
            XCTFail("The canonical test runner must provision the local E2E fixture on port 9876")
            return
        }
        app.buttons["sessions.settings"].tap()
        app.buttons["settings.connect"].tap()

        app.navigationBars.buttons["Sessions"].tap()
        let session = app.buttons["session.e2e"]
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        session.tap()
        XCTAssertTrue(app.textViews["History restored"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["chat.previousAssistantMessage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chat.nextAssistantMessage"].exists)

        let composer = app.textFields["chat.composer"]
        composer.tap()
        composer.typeText("Live prompt")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.textViews["Streaming complete"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "작업 기록")).count, 0)
        XCTAssertFalse(app.staticTexts["read"].exists)
        XCTAssertFalse(app.otherElements.matching(
            NSPredicate(format: "label == %@", "Session status")
        ).firstMatch.exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertTrue(composer.isHittable)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(app.textViews.matching(NSPredicate(format: "label == %@", "Streaming complete")).count, 1)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "작업 기록")).count, 0)
        app.buttons["chat.menu"].tap()
        let abort = app.buttons["chat.abort"]
        XCTAssertTrue(abort.waitForExistence(timeout: 3))
        abort.tap()
    }

    func testVoiceOverSemanticsAndNavigation() {
        let connection = app.buttons["connection.status"].firstMatch
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
        let add = app.buttons["chat.add"]
        XCTAssertTrue(add.isHittable)
        XCTAssertGreaterThanOrEqual(add.frame.minY, composer.frame.maxY)
        XCTAssertLessThan(composer.frame.minX, add.frame.maxX)
        XCTAssertGreaterThanOrEqual(add.frame.width, 44)
        XCTAssertGreaterThanOrEqual(add.frame.height, 44)
        let stop = app.buttons["chat.stop"]
        XCTAssertEqual(stop.label, "Stop current run")
        XCTAssertTrue(stop.isEnabled)
        XCTAssertEqual(add.frame.midY, stop.frame.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(stop.frame.width, 44)
        XCTAssertGreaterThanOrEqual(stop.frame.height, 44)
        XCTAssertFalse(app.buttons["chat.send"].exists)

        let previousMessage = app.buttons["chat.previousAssistantMessage"]
        let nextMessage = app.buttons["chat.nextAssistantMessage"]
        XCTAssertGreaterThanOrEqual(previousMessage.frame.width, 44)
        XCTAssertGreaterThanOrEqual(previousMessage.frame.height, 44)
        XCTAssertGreaterThanOrEqual(nextMessage.frame.width, 44)
        XCTAssertGreaterThanOrEqual(nextMessage.frame.height, 44)
        previousMessage.tap()
        Thread.sleep(forTimeInterval: 0.8)
        let previousText = app.descendants(matching: .any)["assistant.message.m0a"]
        XCTAssertTrue(previousText.waitForExistence(timeout: 5))
        XCTAssertTrue(previousText.isHittable)
        nextMessage.tap()
        Thread.sleep(forTimeInterval: 0.8)
        let nextText = app.descendants(matching: .any)["assistant.message.m2"]
        XCTAssertTrue(nextText.waitForExistence(timeout: 5))
        XCTAssertTrue(nextText.isHittable)
        XCTAssertTrue(app.textViews["작업 흐름"].exists)
        XCTAssertFalse(app.textViews["## 작업 흐름"].exists)
        XCTAssertTrue(app.textViews["세션 목록에서 작업 선택"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["chat.progress"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "작업 기록")).count, 0)
        XCTAssertTrue(app.buttons["chat.menu"].isHittable)
    }

    func testPermissionInteractionAppearsAndCanBeAllowed() {
        let card = app.descendants(matching: .any)["interaction.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Permission required"].exists)
        XCTAssertFalse(app.textFields["chat.composer"].exists)
        let allow = app.buttons["Allow"]
        XCTAssertTrue(allow.isHittable)
        allow.tap()
        XCTAssertFalse(card.waitForExistence(timeout: 1))
        XCTAssertTrue(app.textFields["chat.composer"].waitForExistence(timeout: 3))
    }

    func testManualScrollResynchronizesAssistantNavigation() {
        let session = app.buttons["session.mobile"]
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()

        let previous = app.buttons["chat.previousAssistantMessage"]
        previous.tap()
        Thread.sleep(forTimeInterval: 0.8)
        let firstAssistant = app.descendants(matching: .any)["assistant.message.m0a"]
        XCTAssertTrue(firstAssistant.isHittable)

        let transcript = app.scrollViews["chat.transcript"]
        let secondAssistant = app.descendants(matching: .any)["assistant.message.m2"]
        for _ in 0..<3 where !secondAssistant.isHittable {
            transcript.swipeUp()
        }
        XCTAssertTrue(secondAssistant.isHittable)
        Thread.sleep(forTimeInterval: 0.5)

        previous.tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(firstAssistant.isHittable)
    }

    func testPairingAndConnectionControlsAreAccessible() {
        app.buttons["sessions.settings"].tap()
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
        XCTAssertTrue(scrollToExistence(app.staticTexts["Answer alerts"]))
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

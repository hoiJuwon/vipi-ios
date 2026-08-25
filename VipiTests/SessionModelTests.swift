import XCTest
@testable import Vipi

final class SessionModelTests: XCTestCase {
    func testMobileMarkdownParsesReadableBlocksAndCapsHeadingLevels() {
        let source = """
        # 큰 제목
        ### 작은 제목

        본문에 **강조**와 `코드`

        - 항목
        - [x] 완료
        1. 순서
        > 인용
        ---
        ```swift
        let value = 1
        ```
        """

        XCTAssertEqual(
            MobileMarkdownParser.parse(source),
            [
                .heading(level: 1, text: "큰 제목"),
                .heading(level: 3, text: "작은 제목"),
                .paragraph("본문에 **강조**와 `코드`"),
                .unorderedItem(marker: "•", text: "항목"),
                .unorderedItem(marker: "checkmark.square.fill", text: "완료"),
                .orderedItem(number: "1.", text: "순서"),
                .quote("인용"),
                .divider,
                .code(language: "swift", text: "let value = 1")
            ]
        )
    }

    func testWorkspaceGroupingKeepsWorkingWorkspaceFirst() async {
        let store = await AppStore(startsInDemoMode: true)
        let groups = await store.workspaceGroups
        XCTAssertFalse(groups.isEmpty)
        XCTAssertTrue(groups[0].sessions.contains { $0.phase == .working })
    }

    func testMockConversationHasWorkingSessionAndPendingAnswer() {
        let messages = MockData.messages["mobile"] ?? []
        XCTAssertTrue(messages.contains(where: \.isStreaming))
        XCTAssertEqual(MockData.sessions.first(where: { $0.id == "mobile" })?.phase, .working)
    }

    @MainActor func testOpeningSessionOptimisticallyMarksItRead() async {
        let store = AppStore(startsInDemoMode: true)
        XCTAssertEqual(store.session(id: "ui")?.unread, true)
        await store.markRead("ui")
        XCTAssertEqual(store.session(id: "ui")?.unread, false)
    }

    @MainActor func testUnreadSnapshotStaysReadWhileChatIsOpen() async throws {
        let store = AppStore()
        store.selectedSessionID = "open-session"
        let data = Data(#"{"type":"sessions.snapshot","payload":{"sessions":[{"id":"open-session","name":"Open","cwd":"/tmp","phase":"completed","unread":true,"lastActivityAt":"2026-08-24T00:00:00Z","model":"Pi","thinkingLevel":"off","contextPercent":0,"tmux":{"session":"base","window":"1","paneID":"%1"}}]}}"#.utf8)
        await store.handle(try JSONDecoder().decode(ServerEnvelope.self, from: data))
        XCTAssertEqual(store.session(id: "open-session")?.unread, false)
    }

    @MainActor func testDraftsRemainPerSessionAcrossChatNavigation() {
        let store = AppStore()
        store.setDraft("first draft", for: "session-a")
        store.setDraft("second draft", for: "session-b")

        XCTAssertEqual(store.draft(for: "session-a"), "first draft")
        XCTAssertEqual(store.draft(for: "session-b"), "second draft")

        store.setDraft("", for: "session-a")
        XCTAssertEqual(store.draft(for: "session-a"), "")
        XCTAssertEqual(store.draft(for: "session-b"), "second draft")
    }

    @MainActor func testSelectedAssistantExcerptsRemainPerSessionAndCanBeRemoved() {
        let store = AppStore()
        store.addAnnotation(messageID: "answer-a", text: "  selected answer text  ", to: "session-a")
        store.addAnnotation(messageID: "answer-a", text: "selected answer text", to: "session-a")
        store.addAnnotation(messageID: "answer-b", text: "another answer", to: "session-b")

        XCTAssertEqual(store.annotations(for: "session-a").map(\.text), ["selected answer text"])
        XCTAssertEqual(store.annotations(for: "session-b").map(\.text), ["another answer"])
        let annotationID = store.annotations(for: "session-a")[0].id
        store.removeAnnotation(annotationID, from: "session-a")
        XCTAssertTrue(store.annotations(for: "session-a").isEmpty)
        XCTAssertEqual(store.annotations(for: "session-b").count, 1)
    }

    @MainActor func testWorkingPromptIsQueuedUntilItsUserMessageStarts() async throws {
        let store = AppStore(startsInDemoMode: true)
        let originalCount = store.messages(for: "mobile").count
        await store.send(text: "queued follow-up", to: "mobile", delivery: .followUp)

        XCTAssertEqual(store.queuedPrompts(for: "mobile").map(\.text), ["queued follow-up"])
        XCTAssertEqual(store.messages(for: "mobile").count, originalCount)

        let json = #"{"type":"session.event","payload":{"sessionID":"mobile","event":{"kind":"message","messageID":"queued-user","role":"user","text":"queued follow-up","timestamp":"2026-08-24T00:00:00Z","streaming":false}}}"#
        let envelope = try JSONDecoder().decode(ServerEnvelope.self, from: Data(json.utf8))
        await store.handle(envelope)
        XCTAssertTrue(store.queuedPrompts(for: "mobile").isEmpty)
        XCTAssertEqual(store.messages(for: "mobile").last?.text, "queued follow-up")
    }

    @MainActor func testMessagesAndMinimalProgressAreReducedWithoutToolPayloads() async throws {
        let store = AppStore()
        store.messagesBySession["wire"] = []
        func envelope(_ event: String) throws -> ServerEnvelope {
            let json = #"{"type":"session.event","seq":2,"payload":{"sessionID":"wire","event":\#(event)}}"#
            return try JSONDecoder().decode(ServerEnvelope.self, from: Data(json.utf8))
        }
        try await store.handle(envelope(#"{"kind":"progress","activity":"editing","timestamp":"2026-08-24T00:00:00Z"}"#))
        XCTAssertEqual(store.progressActivity(for: "wire"), .editing)
        XCTAssertTrue(store.messages(for: "wire").isEmpty)
        try await store.handle(envelope(#"{"kind":"message","messageID":"m1","role":"assistant","text":"완료했습니다.","timestamp":"2026-08-24T00:00:01Z","streaming":false}"#))
        XCTAssertEqual(store.messages(for: "wire").map(\.text), ["완료했습니다."])
    }

    @MainActor func testProductionConnectRejectsInsecureHostBeforeBroker() async {
        let store = AppStore()
        store.host = "http://public.example.com"
        store.token = String(repeating: "t", count: 43)
        await store.connect()
        XCTAssertEqual(store.connectionState, .disconnected("Vipi requires an HTTPS .ts.net Tailscale host."))
    }

    @MainActor func testProductionStoreStartsEmptyAndDisconnected() {
        let store = AppStore()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(store.messagesBySession.isEmpty)
        XCTAssertEqual(store.connectionState, .disconnected(nil))
    }

    @MainActor func testDisconnectedCommandsSurfaceErrors() async {
        let store = AppStore()
        await store.send(text: "must not be fabricated", to: "mobile", delivery: .prompt)
        XCTAssertTrue(store.messages(for: "mobile").isEmpty)
        XCTAssertEqual(store.commandError, "The prompt was not sent because the host is disconnected.")
        store.commandError = nil
        await store.abort(sessionID: "mobile")
        XCTAssertNotNil(store.commandError)
        store.commandError = nil
        await store.compact(sessionID: "mobile")
        XCTAssertNotNil(store.commandError)
        store.commandError = nil
        let rejected = try! JSONDecoder().decode(
            ServerEnvelope.self,
            from: Data(#"{"id":"command","type":"session.response","payload":{"requestID":"command","ok":false,"result":{"error":"runtime rejected"}}}"#.utf8)
        )
        await store.handle(rejected)
        XCTAssertEqual(store.commandError, "runtime rejected")
    }

    @MainActor func testLiveHistorySettlementAndReplayResetDoNotDuplicateMessages() async throws {
        let store = AppStore()
        store.messagesBySession["reconcile"] = []
        func event(_ value: String) throws -> ServerEnvelope {
            try JSONDecoder().decode(
                ServerEnvelope.self,
                from: Data(#"{"type":"session.event","payload":{"sessionID":"reconcile","event":\#(value)}}"#.utf8)
            )
        }
        let timestamp = "2026-08-24T00:00:00Z"
        await store.handle(try event(#"{"kind":"message","messageID":"transient","role":"assistant","text":"settled answer","timestamp":"\#(timestamp)","streaming":false}"#))
        func history(_ id: String, replacesTransient: Bool) throws -> ServerEnvelope {
            let replacement = replacesTransient ? ",\"replacesMessageID\":\"transient\"" : ""
            let json = #"{"id":"\#(id)","type":"session.response","payload":{"requestID":"\#(id)","ok":true,"result":{"events":[{"kind":"message","messageID":"entry-2"\#(replacement),"entryID":"entry-2","role":"assistant","text":"settled answer","timestamp":"\#(timestamp)","streaming":false}],"lastEntryID":"entry-2"}}}"#
            return try JSONDecoder().decode(ServerEnvelope.self, from: Data(json.utf8))
        }
        store.registerHistoryRequestForTesting(id: "history-1", sessionID: "reconcile")
        await store.handle(try history("history-1", replacesTransient: true))
        store.registerHistoryRequestForTesting(id: "history-2", sessionID: "reconcile")
        await store.handle(try history("history-2", replacesTransient: false))
        XCTAssertEqual(store.messages(for: "reconcile").count, 1)
        XCTAssertEqual(store.messages(for: "reconcile").first?.id, "entry-2")
        XCTAssertEqual(store.lastEntryForTesting(sessionID: "reconcile"), "entry-2")

        let reset = try JSONDecoder().decode(
            ServerEnvelope.self,
            from: Data(#"{"type":"sessions.snapshot","payload":{"sessions":[],"replayReset":true}}"#.utf8)
        )
        await store.handle(reset)
        XCTAssertNil(store.lastEntryForTesting(sessionID: "reconcile"))
        store.registerHistoryRequestForTesting(id: "history-3", sessionID: "reconcile")
        await store.handle(try history("history-3", replacesTransient: false))
        XCTAssertEqual(store.messages(for: "reconcile").count, 1)
        XCTAssertEqual(store.lastEntryForTesting(sessionID: "reconcile"), "entry-2")
    }

    @MainActor func testTokenRotationUpdatesReconnectCredentialsBeforeReturning() async throws {
        let broker = BrokerClient(reconnectHost: "https://mac.example.ts.net", token: "old-token")
        let store = AppStore(broker: broker)
        let rotated = String(repeating: "r", count: 43)
        let data = Data(#"{"id":"rotate","type":"auth.rotated","seq":9,"payload":{"token":"\#(rotated)"}}"#.utf8)
        let envelope = try JSONDecoder().decode(ServerEnvelope.self, from: data)
        await store.handle(envelope)
        XCTAssertEqual(store.token, rotated)
        let reconnectToken = await broker.reconnectTokenForTesting()
        XCTAssertEqual(reconnectToken, rotated)
    }

    func testProductionEndpointPolicyRequiresTailnetHTTPS() throws {
        let endpoint = try TailscaleEndpoint.parse("https://mac.example-tailnet.ts.net")
        XCTAssertEqual(endpoint.webSocketURL.absoluteString, "wss://mac.example-tailnet.ts.net/ws")
        XCTAssertThrowsError(try TailscaleEndpoint.parse("http://127.0.0.1:9876"))
        XCTAssertThrowsError(try TailscaleEndpoint.parse("https://public.example.com"))
        XCTAssertThrowsError(try TailscaleEndpoint.parse("https://mac.example-tailnet.ts.net/path"))
        XCTAssertEqual(
            try TailscaleEndpoint.parse(
                "http://127.0.0.1:9876",
                allowsInsecureLocalhostForUITesting: true
            ).webSocketURL.absoluteString,
            "ws://127.0.0.1:9876/ws"
        )
    }

    func testSessionSearchMatchesTitleOnly() {
        let session = MockData.sessions[0]
        XCTAssertTrue(SessionListSearch.matches(session, query: "모바일 세션"))
        XCTAssertFalse(SessionListSearch.matches(session, query: "vipi-ios"))
    }

    func testSessionListTimesUseKSTAndKakaoStyleGranularity() throws {
        let parser = ISO8601DateFormatter()
        let now = try XCTUnwrap(parser.date(from: "2026-08-24T13:00:00Z"))
        let sameDay = try XCTUnwrap(parser.date(from: "2026-08-24T12:45:00Z"))
        let previousDay = try XCTUnwrap(parser.date(from: "2026-08-23T12:45:00Z"))
        let previousYear = try XCTUnwrap(parser.date(from: "2025-08-24T12:45:00Z"))

        XCTAssertEqual(SessionListTimeFormatter.string(from: sameDay, now: now), "9:45 PM")
        XCTAssertEqual(SessionListTimeFormatter.string(from: previousDay, now: now), "Aug 23")
        XCTAssertEqual(SessionListTimeFormatter.string(from: previousYear, now: now), "2025.08.24")
    }

    @MainActor func testSecurePairingPayloadAndKeychainRoundTrip() throws {
        KeychainStore.deleteToken()
        defer { KeychainStore.deleteToken() }
        let store = AppStore()
        let token = String(repeating: "a", count: 43)
        try KeychainStore.saveToken(token)
        try store.pair(payload: #"{"host":"https://mac.example.ts.net","token":"\#(token)"}"#)
        XCTAssertEqual(store.host, "https://mac.example.ts.net")
        XCTAssertEqual(KeychainStore.loadToken(), token)
        XCTAssertThrowsError(try store.pair(payload: #"{"host":"http://public.example.com","token":"\#(token)"}"#))
        XCTAssertThrowsError(try store.pair(payload: #"{"host":"https://public.example.com","token":"\#(token)"}"#))
    }
}

import XCTest
@testable import Vipi

final class SessionModelTests: XCTestCase {
    func testWorkspaceGroupingKeepsWorkingWorkspaceFirst() async {
        let store = await AppStore()
        let groups = await store.workspaceGroups
        XCTAssertFalse(groups.isEmpty)
        XCTAssertTrue(groups[0].sessions.contains { $0.phase == .working })
    }

    func testMockConversationHasStreamingToolActivity() {
        let messages = MockData.messages["mobile"] ?? []
        XCTAssertTrue(messages.contains(where: \.isStreaming))
        XCTAssertTrue(messages.flatMap(\.tools).contains { $0.state == .running })
    }

    @MainActor func testNormalizedStreamingAndToolEventsAreReducedIncrementally() async throws {
        let store = AppStore()
        store.messagesBySession["wire"] = []
        func envelope(_ event: String) throws -> ServerEnvelope {
            let json = #"{"type":"session.event","seq":2,"payload":{"sessionID":"wire","event":\#(event)}}"#
            return try JSONDecoder().decode(ServerEnvelope.self, from: Data(json.utf8))
        }
        try await store.handle(envelope(#"{"kind":"message","messageID":"m1","role":"assistant","text":"A","timestamp":"2026-08-24T00:00:00Z","streaming":true}"#))
        try await store.handle(envelope(#"{"kind":"message","messageID":"m1","role":"assistant","text":"AB","timestamp":"2026-08-24T00:00:00Z","streaming":false}"#))
        try await store.handle(envelope(#"{"kind":"tool","toolCallID":"t1","name":"read","state":"succeeded","summary":"read completed"}"#))
        XCTAssertEqual(store.messages(for: "wire").count, 1)
        XCTAssertEqual(store.messages(for: "wire")[0].text, "AB")
        XCTAssertFalse(store.messages(for: "wire")[0].isStreaming)
        XCTAssertEqual(store.messages(for: "wire")[0].tools.first?.state, .succeeded)
    }

    @MainActor func testDisconnectedCommandsSurfaceErrors() async {
        let store = AppStore()
        await store.abort(sessionID: "mobile")
        XCTAssertNotNil(store.commandError)
        store.commandError = nil
        await store.compact(sessionID: "mobile")
        XCTAssertNotNil(store.commandError)
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
    }
}

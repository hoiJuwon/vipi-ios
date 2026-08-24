import XCTest
@testable import Vipi

final class SessionModelTests: XCTestCase {
    func testWorkspaceGroupingKeepsWorkingWorkspaceFirst() async {
        let store = await AppStore(startsInDemoMode: true)
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

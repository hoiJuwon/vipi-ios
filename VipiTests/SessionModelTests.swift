import Security
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

    @MainActor func testNormalizedStreamingAndToolEventsAreReducedIncrementally() throws {
        let store = AppStore()
        store.messagesBySession["wire"] = []
        func envelope(_ event: String) throws -> ServerEnvelope {
            let json = #"{"type":"session.event","seq":2,"payload":{"sessionID":"wire","event":\#(event)}}"#
            return try JSONDecoder().decode(ServerEnvelope.self, from: Data(json.utf8))
        }
        try store.handle(envelope(#"{"kind":"message","messageID":"m1","role":"assistant","text":"A","timestamp":"2026-08-24T00:00:00Z","streaming":true}"#))
        try store.handle(envelope(#"{"kind":"message","messageID":"m1","role":"assistant","text":"AB","timestamp":"2026-08-24T00:00:00Z","streaming":false}"#))
        try store.handle(envelope(#"{"kind":"tool","toolCallID":"t1","name":"read","state":"succeeded","summary":"read completed"}"#))
        XCTAssertEqual(store.messages(for: "wire").count, 1)
        XCTAssertEqual(store.messages(for: "wire")[0].text, "AB")
        XCTAssertFalse(store.messages(for: "wire")[0].isStreaming)
        XCTAssertEqual(store.messages(for: "wire")[0].tools.first?.state, .succeeded)
    }

    @MainActor func testSecurePairingPayloadAndKeychainRoundTrip() throws {
        KeychainStore.deleteToken()
        defer { KeychainStore.deleteToken() }
        let store = AppStore()
        let token = String(repeating: "a", count: 43)
        do {
            try KeychainStore.saveToken(token)
        } catch KeychainError.status(let status) where status == errSecMissingEntitlement {
            throw XCTSkip("Unsigned simulator test host has no Keychain entitlement")
        }
        try store.pair(payload: #"{"host":"https://mac.example.ts.net","token":"\#(token)"}"#)
        XCTAssertEqual(store.host, "https://mac.example.ts.net")
        XCTAssertEqual(KeychainStore.loadToken(), token)
        XCTAssertThrowsError(try store.pair(payload: #"{"host":"http://public.example.com","token":"\#(token)"}"#))
    }
}

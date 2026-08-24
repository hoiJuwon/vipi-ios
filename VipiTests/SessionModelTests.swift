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

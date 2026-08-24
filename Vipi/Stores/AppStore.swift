import Foundation
import Observation

@MainActor @Observable
final class AppStore {
    enum ConnectionState: Equatable { case demo, connecting, connected, disconnected(String?) }

    var sessions: [RemoteSession] = MockData.sessions
    var messagesBySession: [String: [ChatMessage]] = MockData.messages
    var branchesBySession: [String: [BranchNode]] = MockData.branches
    var connectionState: ConnectionState = .demo
    var host = "https://mac-studio.tail0f97ca.ts.net"
    var token = ""
    var selectedSessionID: String?
    var showingSettings = false
    var activityItems = MockData.activity

    private let broker = BrokerClient()

    init() {
        token = KeychainStore.loadToken() ?? ""
        host = UserDefaults.standard.string(forKey: "vipi.host") ?? ""
    }

    var workspaceGroups: [WorkspaceGroup] {
        Dictionary(grouping: sessions, by: \.cwd)
            .map { WorkspaceGroup(path: $0.key, sessions: $0.value.sorted { $0.lastActivityAt > $1.lastActivityAt }) }
            .sorted { lhs, rhs in
                let lhsWorking = lhs.sessions.contains { $0.phase == .working }
                let rhsWorking = rhs.sessions.contains { $0.phase == .working }
                return lhsWorking == rhsWorking ? lhs.path < rhs.path : lhsWorking
            }
    }

    func session(id: String) -> RemoteSession? { sessions.first { $0.id == id } }
    func messages(for id: String) -> [ChatMessage] { messagesBySession[id] ?? [] }
    func branches(for id: String) -> [BranchNode] { branchesBySession[id] ?? [] }

    func connect() async {
        guard !host.isEmpty, !token.isEmpty else {
            connectionState = .disconnected("Host and token are required")
            return
        }
        connectionState = .connecting
        do {
            await broker.setEnvelopeHandler { [weak self] envelope in
                await self?.handle(envelope)
            }
            try await broker.connect(host: host, token: token)
            connectionState = .connected
            try await broker.send(type: "sessions.list", payload: EmptyPayload())
        } catch {
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    func useDemoMode() {
        Task { await broker.disconnect() }
        sessions = MockData.sessions
        messagesBySession = MockData.messages
        connectionState = .demo
    }

    func pair(payload: String) throws {
        guard let data = payload.data(using: .utf8) else { throw PairingError.invalidPayload }
        let pairing = try JSONDecoder().decode(PairingPayload.self, from: data)
        guard let components = URLComponents(string: pairing.host),
              components.scheme == "https" || (components.scheme == "http" && components.host == "127.0.0.1"),
              pairing.token.count >= 32 else { throw PairingError.invalidPayload }
        host = pairing.host
        token = pairing.token
        UserDefaults.standard.set(host, forKey: "vipi.host")
        try KeychainStore.saveToken(token)
    }

    func rotateToken() async {
        guard connectionState == .connected else { return }
        do {
            try await broker.send(type: "auth.rotate", payload: EmptyPayload())
        } catch {
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    func send(text: String, to sessionID: String, delivery: PromptDelivery) async {
        let message = ChatMessage(id: UUID().uuidString, role: .user, text: text, timestamp: .now)
        messagesBySession[sessionID, default: []].append(message)
        if connectionState == .connected {
            try? await broker.send(type: "session.prompt", payload: PromptPayload(sessionID: sessionID, text: text, delivery: delivery))
        } else {
            simulateReply(sessionID: sessionID)
        }
    }

    func abort(sessionID: String) async {
        guard connectionState == .connected else { return }
        try? await broker.send(type: "session.abort", payload: SessionCommandPayload(sessionID: sessionID))
    }

    func markRead(_ sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].unread = false
    }

    private func simulateReply(sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].phase = .working
        let pending = ChatMessage(
            id: UUID().uuidString,
            role: .assistant,
            text: "좋아요. 현재 세션의 맥락을 이어서 확인하고 있습니다…",
            timestamp: .now,
            isStreaming: true,
            tools: [ToolActivity(id: UUID().uuidString, name: "read", summary: "프로젝트 구조 확인", detail: "Sources와 최근 변경 파일", state: .running)]
        )
        messagesBySession[sessionID, default: []].append(pending)
    }

    private func handle(_ envelope: ServerEnvelope) {
        // Typed event reducers are intentionally centralized here. The host
        // protocol can evolve without coupling wire payloads to SwiftUI views.
        if envelope.type == "auth.ok" {
            connectionState = .connected
            UserDefaults.standard.set(host, forKey: "vipi.host")
            try? KeychainStore.saveToken(token)
            return
        }
        if envelope.type == "auth.rotated",
           case .object(let payload) = envelope.payload,
           case .string(let rotatedToken) = payload["token"] {
            token = rotatedToken
            try? KeychainStore.saveToken(rotatedToken)
            return
        }
        if envelope.type == "sessions.snapshot", let payload = envelope.payload {
            do {
                let data = try JSONEncoder().encode(payload)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                sessions = try decoder.decode(SessionSnapshot.self, from: data).sessions
            } catch {
                connectionState = .disconnected("Invalid session snapshot")
            }
        }
    }
}

private struct SessionSnapshot: Decodable {
    let sessions: [RemoteSession]
}

private struct EmptyPayload: Encodable {}

enum PairingError: LocalizedError {
    case invalidPayload
    var errorDescription: String? { "The pairing payload is invalid or not secure." }
}

extension BrokerClient {
    func setEnvelopeHandler(_ handler: @escaping @Sendable (ServerEnvelope) async -> Void) {
        onEnvelope = handler
    }
}

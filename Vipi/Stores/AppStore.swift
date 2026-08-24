import Foundation
import Observation

@MainActor @Observable
final class AppStore {
    enum ConnectionState: Equatable { case demo, connecting, connected, disconnected(String?) }

    var sessions: [RemoteSession] = []
    var messagesBySession: [String: [ChatMessage]] = [:]
    var branchesBySession: [String: [BranchNode]] = [:]
    var connectionState: ConnectionState = .disconnected(nil)
    var host = ""
    var token = ""
    var selectedSessionID: String?
    var showingSettings = false
    var activityItems: [ActivityItem] = []
    var commandError: String?

    private let broker: BrokerClient
    private let allowsInsecureLocalhostForUITesting: Bool
    private var lastEntryBySession: [String: String] = [:]
    private var pendingHistoryRequests: [String: String] = [:]

    init(
        broker: BrokerClient = BrokerClient(),
        allowsInsecureLocalhostForUITesting: Bool = false,
        startsInDemoMode: Bool = false
    ) {
        self.broker = broker
        self.allowsInsecureLocalhostForUITesting = allowsInsecureLocalhostForUITesting
        if CommandLine.arguments.contains("--uitesting"),
           let fixture = ProcessInfo.processInfo.environment["VIPI_E2E_PAIRING"],
           let data = fixture.data(using: .utf8),
           let pairing = try? JSONDecoder().decode(PairingPayload.self, from: data) {
            host = pairing.host
            token = pairing.token
        } else {
            token = KeychainStore.loadToken() ?? ""
            host = UserDefaults.standard.string(forKey: "vipi.host") ?? ""
        }
        if startsInDemoMode { loadDemoData() }
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
        do {
            let endpoint = try TailscaleEndpoint.parse(
                host,
                allowsInsecureLocalhostForUITesting: allowsInsecureLocalhostForUITesting
            )
            host = endpoint.publicURL.absoluteString
        } catch {
            connectionState = .disconnected(error.localizedDescription)
            return
        }
        connectionState = .connecting
        do {
            await broker.setEnvelopeHandler { [weak self] envelope in
                await self?.handle(envelope)
            }
            try await broker.connect(host: host, token: token)
        } catch {
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    func useDemoMode() {
        Task { await broker.disconnect() }
        loadDemoData()
    }

    private func loadDemoData() {
        sessions = MockData.sessions
        messagesBySession = MockData.messages
        branchesBySession = MockData.branches
        activityItems = MockData.activity
        connectionState = .demo
    }

    func pair(payload: String) throws {
        guard let data = payload.data(using: .utf8) else { throw PairingError.invalidPayload }
        let pairing = try JSONDecoder().decode(PairingPayload.self, from: data)
        guard pairing.token.count >= 32 else { throw PairingError.invalidPayload }
        let endpoint: TailscaleEndpoint
        do {
            endpoint = try TailscaleEndpoint.parse(
                pairing.host,
                allowsInsecureLocalhostForUITesting: allowsInsecureLocalhostForUITesting
            )
        } catch {
            throw PairingError.invalidPayload
        }
        host = endpoint.publicURL.absoluteString
        token = pairing.token
        UserDefaults.standard.set(host, forKey: "vipi.host")
        try KeychainStore.saveToken(token)
    }

    func rotateToken() async {
        guard connectionState == .connected else { return }
        do {
            _ = try await broker.send(type: "auth.rotate", payload: EmptyPayload())
        } catch {
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    func send(text: String, to sessionID: String, delivery: PromptDelivery) async {
        let message = ChatMessage(id: UUID().uuidString, role: .user, text: text, timestamp: .now)
        if connectionState == .demo {
            messagesBySession[sessionID, default: []].append(message)
            simulateReply(sessionID: sessionID)
            return
        }
        guard connectionState == .connected else {
            commandError = "The prompt was not sent because the host is disconnected."
            return
        }
        do {
            _ = try await broker.send(type: "session.prompt", payload: PromptPayload(sessionID: sessionID, text: text, delivery: delivery))
            messagesBySession[sessionID, default: []].append(message)
        } catch {
            commandError = "Prompt could not be delivered: \(error.localizedDescription)"
        }
    }

    func abort(sessionID: String) async {
        guard connectionState == .connected else {
            commandError = "The session is not connected."
            return
        }
        do {
            _ = try await broker.send(type: "session.abort", payload: SessionCommandPayload(sessionID: sessionID))
        } catch {
            commandError = "Abort could not be delivered: \(error.localizedDescription)"
        }
    }

    func compact(sessionID: String) async {
        guard connectionState == .connected else {
            commandError = "The session is not connected."
            return
        }
        do {
            _ = try await broker.send(type: "session.compact", payload: SessionCommandPayload(sessionID: sessionID))
        } catch {
            commandError = "Compaction could not be started: \(error.localizedDescription)"
        }
    }

    func markRead(_ sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].unread = false
    }

    private func requestHistory(for sessionID: String) async {
        do {
            let requestID = try await broker.send(
                type: "session.history",
                payload: HistoryPayload(sessionID: sessionID, afterEntryID: lastEntryBySession[sessionID])
            )
            pendingHistoryRequests[requestID] = sessionID
        } catch {
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    private func reduceSessionEvent(_ payload: JSONValue) {
        guard let value: SessionEventPayload = decode(payload) else { return }
        apply(value.event, to: value.sessionID)
    }

    private func reduceHistoryResponse(_ payload: JSONValue, sessionID: String) {
        guard let response: HistoryResponsePayload = decode(payload), response.ok,
              let result = response.result else { return }
        for event in result.events { apply(event, to: sessionID) }
        if let lastEntryID = result.lastEntryID { lastEntryBySession[sessionID] = lastEntryID }
    }

    private func apply(_ event: NormalizedEvent, to sessionID: String) {
        if event.kind == "message", let role = event.role, let text = event.text {
            let message = ChatMessage(
                id: event.messageID ?? UUID().uuidString,
                role: role,
                text: text,
                timestamp: event.timestamp ?? .now,
                isStreaming: event.streaming ?? false
            )
            var messages = messagesBySession[sessionID, default: []]
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                var updated = message
                updated.tools = messages[index].tools
                messages[index] = updated
            } else { messages.append(message) }
            messagesBySession[sessionID] = messages
        } else if event.kind == "tool", let toolCallID = event.toolCallID, let name = event.name {
            let tool = ToolActivity(
                id: toolCallID,
                name: name,
                summary: event.summary ?? name,
                detail: event.detail,
                state: event.state ?? .running
            )
            var messages = messagesBySession[sessionID, default: []]
            if messages.isEmpty || messages.last?.role == .user {
                messages.append(ChatMessage(id: "tools-\(toolCallID)", role: .assistant, text: "", timestamp: .now))
            }
            guard let messageIndex = messages.indices.last else { return }
            if let toolIndex = messages[messageIndex].tools.firstIndex(where: { $0.id == tool.id }) {
                messages[messageIndex].tools[toolIndex] = tool
            } else {
                messages[messageIndex].tools.append(tool)
            }
            messagesBySession[sessionID] = messages
        }
        if let entryID = event.entryID { lastEntryBySession[sessionID] = entryID }
    }

    private func decode<Value: Decodable>(_ payload: JSONValue) -> Value? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
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

    func handle(_ envelope: ServerEnvelope) async {
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
            await broker.updateToken(rotatedToken)
            try? KeychainStore.saveToken(rotatedToken)
            return
        }
        if envelope.type == "sessions.snapshot", let payload = envelope.payload {
            do {
                let data = try JSONEncoder().encode(payload)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                sessions = try decoder.decode(SessionSnapshot.self, from: data).sessions
                for session in sessions where session.phase != .offline {
                    Task { await requestHistory(for: session.id) }
                }
            } catch {
                connectionState = .disconnected("Invalid session snapshot")
            }
            return
        }
        if envelope.type == "session.event", let payload = envelope.payload {
            reduceSessionEvent(payload)
            return
        }
        if envelope.type == "session.response", let payload = envelope.payload {
            if case .object(let response) = payload,
               case .bool(false) = response["ok"] {
                if case .object(let result) = response["result"],
                   case .string(let error) = result["error"] {
                    commandError = error
                } else {
                    commandError = "The host rejected the command."
                }
            }
            if let id = envelope.id, let sessionID = pendingHistoryRequests.removeValue(forKey: id) {
                reduceHistoryResponse(payload, sessionID: sessionID)
            }
            return
        }
        if envelope.type == "error", case .object(let payload) = envelope.payload,
           case .string(let code) = payload["code"] {
            commandError = code
        }
    }
}

private struct SessionSnapshot: Decodable {
    let sessions: [RemoteSession]
}

private struct HistoryPayload: Encodable {
    let sessionID: String
    let afterEntryID: String?
}

private struct SessionEventPayload: Decodable {
    let sessionID: String
    let event: NormalizedEvent
}

private struct HistoryResponsePayload: Decodable {
    let ok: Bool
    let result: HistoryResult?
}

private struct HistoryResult: Decodable {
    let events: [NormalizedEvent]
    let lastEntryID: String?
}

private struct NormalizedEvent: Decodable {
    let kind: String
    let messageID: String?
    let role: ChatRole?
    let text: String?
    let timestamp: Date?
    let streaming: Bool?
    let toolCallID: String?
    let name: String?
    let state: ToolState?
    let summary: String?
    let detail: String?
    let entryID: String?
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

import Foundation

actor BrokerClient {
    enum State: Sendable, Equatable { case disconnected, connecting, connected }
    enum ClientError: Error { case invalidURL, notConnected }

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var credentials: (host: String, token: String)?
    private var lastSeq: Int?
    private var shouldReconnect = false
    private(set) var state: State = .disconnected
    var onEnvelope: (@Sendable (ServerEnvelope) async -> Void)?

    init(reconnectHost: String? = nil, token: String? = nil) {
        if let reconnectHost, let token { credentials = (reconnectHost, token) }
    }

    func connect(host: String, token: String) async throws {
        disconnect(preservingCredentials: true)
        credentials = (host, token)
        shouldReconnect = true
        try await open(host: host, token: token)
    }

    private func open(host: String, token: String) async throws {
        state = .connecting
        guard var components = URLComponents(string: host) else { throw ClientError.invalidURL }
        if components.scheme == "https" { components.scheme = "wss" }
        if components.scheme == "http" { components.scheme = "ws" }
        components.path = "/ws"
        guard let url = components.url else { throw ClientError.invalidURL }

        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        try await send(type: "auth.authenticate", payload: AuthenticatePayload(token: token, lastSeq: lastSeq))
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
    }

    func updateToken(_ token: String) {
        guard let credentials else { return }
        self.credentials = (credentials.host, token)
    }

    func reconnectTokenForTesting() -> String? { credentials?.token }

    func disconnect() {
        shouldReconnect = false
        credentials = nil
        disconnect(preservingCredentials: false)
    }

    private func disconnect(preservingCredentials: Bool) {
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        state = .disconnected
        if !preservingCredentials { credentials = nil }
    }

    @discardableResult
    func send<Payload: Encodable>(type: String, payload: Payload) async throws -> String {
        guard let socket else { throw ClientError.notConnected }
        let id = UUID().uuidString
        let envelope = ClientEnvelope(id: id, type: type, payload: payload)
        let data = try JSONEncoder().encode(envelope)
        try await socket.send(.data(data))
        return id
    }

    private func receiveLoop() async {
        guard let socket else { return }
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: continue
                }
                let envelope = try JSONDecoder().decode(ServerEnvelope.self, from: data)
                if let seq = envelope.seq { lastSeq = max(lastSeq ?? 0, seq) }
                if envelope.type == "auth.ok" { state = .connected }
                await onEnvelope?(envelope)
            } catch {
                state = .disconnected
                self.socket = nil
                if shouldReconnect { scheduleReconnect() }
                break
            }
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil, let credentials else { return }
        reconnectTask = Task { [weak self] in
            for attempt in 0..<8 where !Task.isCancelled {
                let delay = min(pow(2.0, Double(attempt)), 30.0)
                try? await Task.sleep(for: .seconds(delay))
                guard let self, await self.shouldReconnect else { return }
                do {
                    try await self.open(host: credentials.host, token: credentials.token)
                    await self.clearReconnectTask()
                    return
                } catch { continue }
            }
            await self?.clearReconnectTask()
        }
    }

    private func clearReconnectTask() { reconnectTask = nil }
}

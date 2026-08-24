import Foundation

actor BrokerClient {
    enum State: Sendable, Equatable { case disconnected, connecting, connected }
    enum ClientError: Error { case invalidURL, notConnected }

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private(set) var state: State = .disconnected
    var onEnvelope: (@Sendable (ServerEnvelope) async -> Void)?

    func connect(host: String, token: String) async throws {
        disconnect()
        state = .connecting
        guard var components = URLComponents(string: host) else { throw ClientError.invalidURL }
        if components.scheme == "https" { components.scheme = "wss" }
        if components.scheme == "http" { components.scheme = "ws" }
        components.path = "/ws"
        guard let url = components.url else { throw ClientError.invalidURL }

        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        state = .connected
        try await send(type: "auth.authenticate", payload: AuthenticatePayload(token: token))
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        state = .disconnected
    }

    func send<Payload: Encodable>(type: String, payload: Payload) async throws {
        guard let socket else { throw ClientError.notConnected }
        let envelope = ClientEnvelope(id: UUID().uuidString, type: type, payload: payload)
        let data = try JSONEncoder().encode(envelope)
        try await socket.send(.data(data))
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
                await onEnvelope?(envelope)
            } catch {
                state = .disconnected
                break
            }
        }
    }
}

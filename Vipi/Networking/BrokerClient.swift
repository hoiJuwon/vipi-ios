import Foundation

actor BrokerClient {
    enum State: Sendable, Equatable { case disconnected, connecting, connected }
    enum ClientError: LocalizedError {
        case invalidURL, notConnected, uploadRejected(Int), invalidUploadResponse

        var errorDescription: String? {
            switch self {
            case .invalidURL: "The Vipi host URL is invalid."
            case .notConnected: "The Vipi host is not connected."
            case .uploadRejected(let status): "The image upload was rejected (HTTP \(status))."
            case .invalidUploadResponse: "The Vipi host returned an invalid image response."
            }
        }
    }

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var credentials: (host: String, token: String)?
    private var lastSeq: Int?
    private var shouldReconnect = false
    private let allowsInsecureLocalhostForUITesting: Bool
    private(set) var state: State = .disconnected
    var onEnvelope: (@Sendable (ServerEnvelope) async -> Void)?

    init(
        reconnectHost: String? = nil,
        token: String? = nil,
        allowsInsecureLocalhostForUITesting: Bool = false
    ) {
        self.allowsInsecureLocalhostForUITesting = allowsInsecureLocalhostForUITesting
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
        let endpoint: TailscaleEndpoint
        do {
            endpoint = try TailscaleEndpoint.parse(
                host,
                allowsInsecureLocalhostForUITesting: allowsInsecureLocalhostForUITesting
            )
        } catch {
            state = .disconnected
            throw error
        }

        let task = URLSession.shared.webSocketTask(with: endpoint.webSocketURL)
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

    func uploadAttachment(_ attachment: DraftImageAttachment, sessionID: String) async throws -> UploadedAttachment {
        guard state == .connected, let credentials else { throw ClientError.notConnected }
        let endpoint = try TailscaleEndpoint.parse(
            credentials.host,
            allowsInsecureLocalhostForUITesting: allowsInsecureLocalhostForUITesting
        )
        let url = endpoint.publicURL.appending(path: "attachments")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue(sessionID, forHTTPHeaderField: "X-Vipi-Session-ID")
        request.setValue(attachment.mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(attachment.id, forHTTPHeaderField: "X-Vipi-Content-SHA256")
        let (data, response) = try await URLSession.shared.upload(for: request, from: attachment.data)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidUploadResponse }
        guard http.statusCode == 201 else { throw ClientError.uploadRejected(http.statusCode) }
        guard let uploaded = try? JSONDecoder().decode(UploadedAttachment.self, from: data),
              uploaded.digest == attachment.id else { throw ClientError.invalidUploadResponse }
        return uploaded
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

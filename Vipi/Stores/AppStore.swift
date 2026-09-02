import Foundation
import Observation

@MainActor @Observable
final class AppStore {
    enum ConnectionState: Equatable { case demo, connecting, connected, disconnected(String?) }

    var sessions: [RemoteSession] = []
    var messagesBySession: [String: [ChatMessage]] = [:]
    var branchesBySession: [String: [BranchNode]] = [:]
    var connectionState: ConnectionState = .disconnected(nil)
    var codexConnectionState: ConnectionState = .disconnected(nil)
    var selectedProvider: AgentProvider = .pi
    var host = ""
    var token = ""
    var selectedSessionID: String?
    var showingSettings = false
    var activityItems: [ActivityItem] = []
    var draftsBySession: [String: String] = [:]
    var draftImagesBySession: [String: [DraftImageAttachment]] = [:]
    var annotationsBySession: [String: [ChatAnnotation]] = [:]
    var pendingInteractions: [RemoteInteraction] = []
    var queuedPromptsBySession: [String: [QueuedPrompt]] = [:]
    var progressBySession: [String: ProgressActivity] = [:]
    var commandError: String?
    var registeredWorkspaces: [String] = []
    var workspaceHome: String?
    var workspaceDirectory: WorkspaceDirectoryListing?
    var isLoadingWorkspaces = false
    var isBrowsingWorkspace = false
    var isCreatingSession = false
    var sessionCreationSucceeded = false
    var sessionCreationError: String?
    var startingSessionPath: String?
    var pushHostConfigured = false
    var pushRegisteredDevices = 0
    var pushRegistrationError: String?
    var requestedNotificationSessionID: String?
    var notificationRouteRequest = 0

    private let broker: BrokerClient
    private let allowsInsecureLocalhostForUITesting: Bool
    private var lastEntryBySession: [String: String] = [:]
    private var lastMessageAtBySession: [String: Date] = [:]
    private var oldestEntryBySession: [String: String] = [:]
    private var historyHasMoreBySession: [String: Bool] = [:]
    private var pendingHistoryRequests: [String: PendingHistoryRequest] = [:]
    private var historyRequestsInFlight: Set<String> = []
    private var pendingSessionCreationRequests: [String: SessionCreationRequest] = [:]
    private var latestWorkspaceBrowseRequestID: String?
    private var startingSessionPaneID: String?
    private var pendingPushRequests: Set<String> = []
    private var cacheSaveTask: Task<Void, Never>?

    init(
        broker: BrokerClient = BrokerClient(),
        allowsInsecureLocalhostForUITesting: Bool = false,
        startsInDemoMode: Bool = false,
        restoresLocalCache: Bool = true
    ) {
        self.broker = broker
        self.allowsInsecureLocalhostForUITesting = allowsInsecureLocalhostForUITesting
        #if DEBUG
        let acceptsDevelopmentPairing = CommandLine.arguments.contains("--uitesting") || CommandLine.arguments.contains("--simulator-live")
        #else
        let acceptsDevelopmentPairing = false
        #endif
        if acceptsDevelopmentPairing,
           let fixture = ProcessInfo.processInfo.environment["VIPI_E2E_PAIRING"],
           let data = fixture.data(using: .utf8),
           let pairing = try? JSONDecoder().decode(PairingPayload.self, from: data) {
            host = pairing.host
            token = pairing.token
        } else {
            #if targetEnvironment(simulator)
            token = KeychainStore.loadToken() ?? UserDefaults.standard.string(forKey: "vipi.simulatorToken") ?? ""
            #else
            token = KeychainStore.loadToken() ?? ""
            #endif
            host = UserDefaults.standard.string(forKey: "vipi.host") ?? ""
        }
        if let storedProvider = UserDefaults.standard.string(forKey: "vipi.selectedProvider").flatMap(AgentProvider.init(rawValue:)) {
            selectedProvider = storedProvider
        }
        if startsInDemoMode { loadDemoData() } else if restoresLocalCache { restoreLocalCache() }
    }

    var visibleSessions: [RemoteSession] {
        sessions.filter { $0.agentProvider == selectedProvider }
    }

    var workspaceGroups: [WorkspaceGroup] {
        Dictionary(grouping: visibleSessions, by: \.cwd)
            .map { WorkspaceGroup(path: $0.key, sessions: $0.value.sorted { $0.lastActivityAt > $1.lastActivityAt }) }
            .sorted { lhs, rhs in
                let lhsWorking = lhs.sessions.contains { $0.phase == .working }
                let rhsWorking = rhs.sessions.contains { $0.phase == .working }
                return lhsWorking == rhsWorking ? lhs.path < rhs.path : lhsWorking
            }
    }

    func session(id: String) -> RemoteSession? { sessions.first { $0.id == id } }
    func connectionState(for provider: AgentProvider) -> ConnectionState {
        guard connectionState == .connected || connectionState == .demo else { return connectionState }
        return provider == .pi ? connectionState : codexConnectionState
    }
    func selectProvider(_ provider: AgentProvider) {
        selectedProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: "vipi.selectedProvider")
    }
    func lastEntryForTesting(sessionID: String) -> String? { lastEntryBySession[sessionID] }
    func registerHistoryRequestForTesting(id: String, sessionID: String, older: Bool = false) {
        pendingHistoryRequests[id] = PendingHistoryRequest(sessionID: sessionID, direction: older ? .older : .initial)
        historyRequestsInFlight.insert(sessionID)
    }
    func messages(for id: String) -> [ChatMessage] { messagesBySession[id] ?? [] }
    func branches(for id: String) -> [BranchNode] { branchesBySession[id] ?? [] }
    func draft(for id: String) -> String { draftsBySession[id] ?? "" }
    func annotations(for id: String) -> [ChatAnnotation] { annotationsBySession[id] ?? [] }
    func draftImages(for id: String) -> [DraftImageAttachment] { draftImagesBySession[id] ?? [] }
    func queuedPrompts(for id: String) -> [QueuedPrompt] { queuedPromptsBySession[id] ?? [] }
    func progressActivity(for id: String) -> ProgressActivity { progressBySession[id] ?? .thinking }
    func setDraft(_ draft: String, for id: String) {
        if draft.isEmpty {
            draftsBySession.removeValue(forKey: id)
        } else {
            draftsBySession[id] = draft
        }
    }
    func addDraftImage(_ attachment: DraftImageAttachment, to sessionID: String) {
        var attachments = draftImagesBySession[sessionID, default: []]
        guard attachments.count < 4, !attachments.contains(where: { $0.id == attachment.id }) else { return }
        do {
            try ChatImageCache.store(attachment)
            attachments.append(attachment)
            draftImagesBySession[sessionID] = attachments
        } catch {
            commandError = "The selected photo could not be stored: \(error.localizedDescription)"
        }
    }
    func removeDraftImage(_ attachmentID: String, from sessionID: String) {
        draftImagesBySession[sessionID]?.removeAll { $0.id == attachmentID }
        if draftImagesBySession[sessionID]?.isEmpty == true { draftImagesBySession.removeValue(forKey: sessionID) }
    }
    func clearDraftImages(for sessionID: String) {
        draftImagesBySession.removeValue(forKey: sessionID)
    }
    func restoreDraftImages(_ attachments: [DraftImageAttachment], for sessionID: String) {
        guard !attachments.isEmpty else { return }
        draftImagesBySession[sessionID] = attachments
    }
    func addAnnotation(messageID: String, text: String, to sessionID: String) {
        let excerpt = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
        guard !excerpt.isEmpty else { return }
        var annotations = annotationsBySession[sessionID, default: []]
        guard !annotations.contains(where: { $0.messageID == messageID && $0.text == excerpt }) else { return }
        if annotations.count == 4 { annotations.removeFirst() }
        annotations.append(ChatAnnotation(messageID: messageID, text: excerpt))
        annotationsBySession[sessionID] = annotations
    }
    func removeAnnotation(_ annotationID: String, from sessionID: String) {
        annotationsBySession[sessionID]?.removeAll { $0.id == annotationID }
        if annotationsBySession[sessionID]?.isEmpty == true { annotationsBySession.removeValue(forKey: sessionID) }
    }
    func clearAnnotations(for sessionID: String) {
        annotationsBySession.removeValue(forKey: sessionID)
    }
    func isHistoryLoading(for id: String) -> Bool { historyRequestsInFlight.contains(id) }
    func canLoadOlderHistory(for id: String) -> Bool { historyHasMoreBySession[id] == true }

    func connectIfConfigured() async {
        guard connectionState != .demo,
              case .disconnected = connectionState,
              !host.isEmpty, !token.isEmpty else { return }
        await connect()
    }

    func ensureHistory(for sessionID: String) async {
        guard connectionState == .connected else { return }
        await requestHistory(
            for: sessionID,
            direction: messages(for: sessionID).isEmpty ? .initial : .incremental
        )
    }

    func loadOlderHistory(for sessionID: String) async {
        guard connectionState == .connected,
              historyHasMoreBySession[sessionID] == true,
              oldestEntryBySession[sessionID] != nil else { return }
        await requestHistory(for: sessionID, direction: .older)
    }

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
        selectedProvider = .pi
        sessions = MockData.sessions
        messagesBySession = MockData.messages
        branchesBySession = MockData.branches
        activityItems = MockData.activity
        connectionState = .demo
        #if DEBUG
        if CommandLine.arguments.contains("--markdown-table-preview") {
            messagesBySession["mobile"] = [ChatMessage(
                id: "markdown-table-preview",
                role: .assistant,
                text: MockData.markdownTablePreview,
                timestamp: .now
            )]
        }
        if CommandLine.arguments.contains("--interaction-preview") {
            pendingInteractions = [RemoteInteraction(
                requestID: "preview-permission",
                sessionID: "mobile",
                kind: .confirm,
                title: "Permission required",
                message: "Allow Pi to continue with this operation?",
                options: nil,
                placeholder: nil
            )]
        }
        #endif
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
        persistSimulatorToken(token)
    }

    func rotateToken() async {
        guard connectionState == .connected else { return }
        do {
            _ = try await broker.send(type: "auth.rotate", payload: EmptyPayload())
        } catch {
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    @discardableResult
    func send(
        text: String,
        annotations: [ChatAnnotation] = [],
        images: [DraftImageAttachment] = [],
        to sessionID: String,
        delivery: PromptDelivery
    ) async -> Bool {
        let message = ChatMessage(
            id: UUID().uuidString,
            role: .user,
            text: text,
            timestamp: .now,
            attachments: images.map(\.chatAttachment)
        )
        if connectionState == .demo {
            if delivery == .followUp {
                enqueuePrompt(text, for: sessionID)
            } else {
                messagesBySession[sessionID, default: []].append(message)
                simulateReply(sessionID: sessionID)
            }
            return true
        }
        guard connectionState == .connected else {
            commandError = "The prompt was not sent because the host is disconnected."
            return false
        }
        do {
            var uploaded: [UploadedAttachment] = []
            for image in images {
                uploaded.append(try await broker.uploadAttachment(image, sessionID: sessionID))
            }
            _ = try await broker.send(
                type: "session.prompt",
                payload: PromptPayload(
                    sessionID: sessionID,
                    clientMessageID: message.id,
                    text: text,
                    delivery: delivery,
                    annotations: annotations,
                    attachments: uploaded.map { PromptAttachmentReference(id: $0.id) }
                )
            )
            if delivery == .followUp {
                enqueuePrompt(text, for: sessionID)
            } else {
                messagesBySession[sessionID, default: []].append(message)
            }
            scheduleLocalCacheSave()
            return true
        } catch {
            commandError = "Prompt could not be delivered: \(error.localizedDescription)"
            return false
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

    func respond(to interaction: RemoteInteraction, with response: JSONValue) async {
        pendingInteractions.removeAll { $0.requestID == interaction.requestID }
        if connectionState == .demo { return }
        guard connectionState == .connected else {
            commandError = "The permission response was not sent because the host is disconnected."
            return
        }
        do {
            _ = try await broker.send(
                type: "session.interaction.respond",
                payload: InteractionResponsePayload(
                    sessionID: interaction.sessionID,
                    requestID: interaction.requestID,
                    response: response
                )
            )
        } catch {
            commandError = "Permission response could not be delivered: \(error.localizedDescription)"
        }
    }

    func markRead(_ sessionID: String) async {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].unread = false
        guard connectionState == .connected else { return }
        do {
            _ = try await broker.send(type: "session.read", payload: SessionCommandPayload(sessionID: sessionID))
        } catch {
            commandError = "Read state could not be synchronized: \(error.localizedDescription)"
        }
    }

    func prepareSessionCreation() async {
        sessionCreationSucceeded = false
        sessionCreationError = nil
        registeredWorkspaces = []
        workspaceHome = nil
        workspaceDirectory = nil
        isBrowsingWorkspace = false
        isLoadingWorkspaces = true

        if connectionState == .demo {
            let paths = Array(Set(sessions.map(\.cwd))).sorted()
            registeredWorkspaces = paths
            workspaceHome = "/Users/choijuwon"
            workspaceDirectory = demoWorkspaceDirectory(at: workspaceHome ?? "/Users/choijuwon")
            isLoadingWorkspaces = false
            return
        }
        guard connectionState == .connected else {
            isLoadingWorkspaces = false
            sessionCreationError = "Connect to the Vipi host before starting a session."
            return
        }
        let requestID = UUID().uuidString
        pendingSessionCreationRequests[requestID] = .workspaces
        do {
            _ = try await broker.send(type: "workspaces.list", payload: EmptyPayload(), id: requestID)
            scheduleSessionCreationTimeout(requestID)
        } catch {
            pendingSessionCreationRequests.removeValue(forKey: requestID)
            isLoadingWorkspaces = false
            sessionCreationError = error.localizedDescription
        }
    }

    func browseWorkspace(_ path: String?) async {
        sessionCreationError = nil
        if connectionState == .demo {
            let target = path ?? workspaceHome ?? "/Users/choijuwon"
            workspaceDirectory = demoWorkspaceDirectory(at: target)
            return
        }
        guard connectionState == .connected else {
            sessionCreationError = "The Vipi host is disconnected."
            return
        }
        isBrowsingWorkspace = true
        let requestID = UUID().uuidString
        latestWorkspaceBrowseRequestID = requestID
        pendingSessionCreationRequests[requestID] = .browse
        do {
            _ = try await broker.send(
                type: "workspaces.browse",
                payload: WorkspaceBrowsePayload(path: path),
                id: requestID
            )
            scheduleSessionCreationTimeout(requestID)
        } catch {
            pendingSessionCreationRequests.removeValue(forKey: requestID)
            isBrowsingWorkspace = false
            sessionCreationError = error.localizedDescription
        }
    }

    func createSession(in path: String) async {
        guard !isCreatingSession else { return }
        sessionCreationSucceeded = false
        sessionCreationError = nil
        isCreatingSession = true
        startingSessionPath = path
        startingSessionPaneID = nil

        if connectionState == .demo {
            let now = Date.now
            sessions.insert(RemoteSession(
                id: "demo-\(UUID().uuidString)",
                provider: selectedProvider,
                name: "기타 / 새 세션",
                cwd: path,
                phase: .idle,
                unread: false,
                lastActivityAt: now,
                model: "Pi",
                thinkingLevel: "—",
                contextPercent: 0,
                tmux: TmuxCoordinates(session: "demo", window: "1", paneID: "%demo"),
                sessionFile: nil
            ), at: 0)
            registeredWorkspaces = Array(Set(registeredWorkspaces + [path])).sorted()
            isCreatingSession = false
            startingSessionPath = nil
            sessionCreationSucceeded = true
            return
        }
        guard connectionState == .connected else {
            isCreatingSession = false
            startingSessionPath = nil
            sessionCreationError = "The Vipi host is disconnected."
            return
        }
        let requestID = UUID().uuidString
        let provider = selectedProvider
        pendingSessionCreationRequests[requestID] = .create(path: path, provider: provider)
        do {
            _ = try await broker.send(
                type: "session.create",
                payload: SessionCreatePayload(cwd: path, provider: provider),
                id: requestID
            )
            scheduleSessionCreationTimeout(requestID, seconds: 15)
        } catch {
            pendingSessionCreationRequests.removeValue(forKey: requestID)
            isCreatingSession = false
            startingSessionPath = nil
            sessionCreationError = error.localizedDescription
        }
    }

    func registerPushDeviceIfAvailable() async {
        guard connectionState == .connected,
              let registration = PushNotificationCoordinator.registration else { return }
        let requestID = UUID().uuidString
        pendingPushRequests.insert(requestID)
        do {
            _ = try await broker.send(
                type: "push.register",
                payload: PushRegistrationPayload(
                    deviceToken: registration.deviceToken,
                    environment: registration.environment
                ),
                id: requestID
            )
        } catch {
            pendingPushRequests.remove(requestID)
            pushRegistrationError = error.localizedDescription
        }
    }

    func refreshPushStatus() async {
        guard connectionState == .connected else { return }
        let requestID = UUID().uuidString
        pendingPushRequests.insert(requestID)
        do {
            _ = try await broker.send(type: "push.status", payload: EmptyPayload(), id: requestID)
        } catch {
            pendingPushRequests.remove(requestID)
            pushRegistrationError = error.localizedDescription
        }
    }

    func requestSessionFromNotification(_ sessionID: String) {
        requestedNotificationSessionID = sessionID
        notificationRouteRequest &+= 1
    }

    func consumeNotificationSessionRequest() {
        requestedNotificationSessionID = nil
    }

    private var localCacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appending(path: "Vipi", directoryHint: .isDirectory).appending(path: "mobile-cache-v2.json")
    }

    private func restoreLocalCache() {
        guard let data = try? Data(contentsOf: localCacheURL),
              let cache = try? JSONDecoder().decode(PersistedMobileCache.self, from: data),
              cache.savedAt > Date.now.addingTimeInterval(-30 * 24 * 60 * 60) else { return }
        sessions = cache.sessions
        messagesBySession = cache.messagesBySession
        lastEntryBySession = cache.lastEntryBySession
        oldestEntryBySession = cache.oldestEntryBySession
        historyHasMoreBySession = cache.historyHasMoreBySession
    }

    private func scheduleLocalCacheSave() {
        cacheSaveTask?.cancel()
        cacheSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.saveLocalCache()
        }
    }

    private func saveLocalCache() {
        let visibleIDs = Set(sessions.map(\.id))
        let messages = messagesBySession.reduce(into: [String: [ChatMessage]]()) { result, pair in
            guard visibleIDs.contains(pair.key) else { return }
            result[pair.key] = Array(pair.value.suffix(50))
        }
        let cache = PersistedMobileCache(
            savedAt: .now,
            sessions: sessions,
            messagesBySession: messages,
            lastEntryBySession: lastEntryBySession.filter { visibleIDs.contains($0.key) },
            oldestEntryBySession: oldestEntryBySession.filter { visibleIDs.contains($0.key) },
            historyHasMoreBySession: historyHasMoreBySession.filter { visibleIDs.contains($0.key) }
        )
        guard let data = try? JSONEncoder().encode(cache) else { return }
        do {
            try FileManager.default.createDirectory(
                at: localCacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            try data.write(to: localCacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: localCacheURL.path)
        } catch {}
    }

    private func demoWorkspaceDirectory(at path: String) -> WorkspaceDirectoryListing {
        let known = Set(sessions.map(\.cwd) + [
            "/Users/choijuwon/Desktop",
            "/Users/choijuwon/Desktop/development",
            "/Users/choijuwon/Desktop/development/works",
        ])
        let directories = known.filter { candidate in
            URL(fileURLWithPath: candidate).deletingLastPathComponent().path == path && candidate != path
        }.sorted()
        let parent = path == "/Users/choijuwon" ? nil : URL(fileURLWithPath: path).deletingLastPathComponent().path
        return WorkspaceDirectoryListing(path: path, parent: parent, directories: directories)
    }

    private func scheduleSessionCreationTimeout(_ requestID: String, seconds: Int = 10) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, let request = self.pendingSessionCreationRequests.removeValue(forKey: requestID) else { return }
            switch request {
            case .workspaces: self.isLoadingWorkspaces = false
            case .browse:
                if self.latestWorkspaceBrowseRequestID == requestID { self.isBrowsingWorkspace = false }
            case .create:
                self.isCreatingSession = false
                self.startingSessionPath = nil
            }
            self.sessionCreationError = "The Vipi host did not respond in time."
        }
    }

    private func requestHistory(for sessionID: String, direction: HistoryDirection) async {
        guard historyRequestsInFlight.insert(sessionID).inserted else { return }
        let payload = HistoryPayload(
            sessionID: sessionID,
            afterEntryID: direction == .incremental ? lastEntryBySession[sessionID] : nil,
            beforeEntryID: direction == .older ? oldestEntryBySession[sessionID] : nil,
            limit: 60
        )
        let requestID = UUID().uuidString
        pendingHistoryRequests[requestID] = PendingHistoryRequest(sessionID: sessionID, direction: direction)
        do {
            _ = try await broker.send(type: "session.history", payload: payload, id: requestID)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard let self, self.pendingHistoryRequests[requestID]?.sessionID == sessionID else { return }
                self.pendingHistoryRequests.removeValue(forKey: requestID)
                self.historyRequestsInFlight.remove(sessionID)
            }
        } catch {
            pendingHistoryRequests.removeValue(forKey: requestID)
            historyRequestsInFlight.remove(sessionID)
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    private func reduceSessionEvent(_ payload: JSONValue) {
        guard let value: SessionEventPayload = decode(payload) else { return }
        apply(value.event, to: value.sessionID)
    }

    private func reduceHistoryResponse(_ payload: JSONValue, request: PendingHistoryRequest) {
        guard let response: HistoryResponsePayload = decode(payload), response.ok,
              let result = response.result else { return }
        let sessionID = request.sessionID
        var messages = messagesBySession[sessionID, default: []]
        var latestMessageAt = lastMessageAtBySession[sessionID]

        // A page is one state transition. Publishing each of up to 60 events
        // separately caused SwiftUI to repeatedly reorder and redraw the
        // transcript while a session was opening.
        for event in result.events {
            if event.kind == "progress", let activity = event.activity {
                progressBySession[sessionID] = activity
            }
            guard let message = chatMessage(from: event) else { continue }
            merge(message, replacing: event.replacesMessageID, into: &messages)
            if message.role == .user { dequeuePrompt(matching: message.text, for: sessionID) }
            if let timestamp = event.timestamp {
                latestMessageAt = max(latestMessageAt ?? .distantPast, timestamp)
            }
        }
        messages.sort { lhs, rhs in
            lhs.timestamp == rhs.timestamp ? lhs.id < rhs.id : lhs.timestamp < rhs.timestamp
        }
        messagesBySession[sessionID] = messages
        if let latestMessageAt {
            lastMessageAtBySession[sessionID] = latestMessageAt
            if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
                sessions[index].lastActivityAt = latestMessageAt
            }
        }

        // Loading an older page must not move the incremental tail cursor
        // backwards. Doing so made the next visit re-fetch and re-merge a
        // large middle section of the conversation.
        if request.direction != .older, let lastEntryID = result.lastEntryID {
            lastEntryBySession[sessionID] = lastEntryID
        }
        if request.direction != .incremental {
            if let oldestEntryID = result.oldestEntryID { oldestEntryBySession[sessionID] = oldestEntryID }
            historyHasMoreBySession[sessionID] = result.hasMore ?? false
        }
        scheduleLocalCacheSave()
    }

    private func apply(_ event: NormalizedEvent, to sessionID: String) {
        if event.kind == "progress", let activity = event.activity {
            progressBySession[sessionID] = activity
            return
        }
        if let message = chatMessage(from: event) {
            var messages = messagesBySession[sessionID, default: []]
            merge(message, replacing: event.replacesMessageID, into: &messages)
            messagesBySession[sessionID] = messages
            if message.role == .user { dequeuePrompt(matching: message.text, for: sessionID) }
            scheduleLocalCacheSave()
            if let timestamp = event.timestamp {
                lastMessageAtBySession[sessionID] = max(lastMessageAtBySession[sessionID] ?? .distantPast, timestamp)
                if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
                    sessions[index].lastActivityAt = lastMessageAtBySession[sessionID] ?? timestamp
                }
            }
        }
        if let entryID = event.entryID { lastEntryBySession[sessionID] = entryID }
    }

    private func chatMessage(from event: NormalizedEvent) -> ChatMessage? {
        guard event.kind == "message", let role = event.role, let text = event.text else { return nil }
        return ChatMessage(
            id: event.messageID ?? UUID().uuidString,
            role: role,
            text: text,
            timestamp: event.timestamp ?? .now,
            isStreaming: event.streaming ?? false,
            attachments: event.attachments ?? []
        )
    }

    private func merge(_ message: ChatMessage, replacing replacedID: String?, into messages: inout [ChatMessage]) {
        let replacementIndex = replacedID.flatMap { id in messages.firstIndex(where: { $0.id == id }) }
        let stableIndex = messages.firstIndex(where: { $0.id == message.id })
        let semanticIndex = messages.firstIndex(where: {
            $0.role == message.role && $0.text == message.text &&
            abs($0.timestamp.timeIntervalSince(message.timestamp)) < 5
        })
        if let index = replacementIndex ?? stableIndex ?? semanticIndex {
            var replacement = message
            if replacement.attachments.isEmpty { replacement.attachments = messages[index].attachments }
            messages[index] = replacement
        } else {
            messages.append(message)
        }
    }

    private func enqueuePrompt(_ text: String, for sessionID: String) {
        guard !queuedPromptsBySession[sessionID, default: []].contains(where: { $0.text == text }) else { return }
        queuedPromptsBySession[sessionID, default: []].append(QueuedPrompt(id: UUID().uuidString, text: text))
    }

    private func dequeuePrompt(matching text: String, for sessionID: String) {
        guard let index = queuedPromptsBySession[sessionID]?.firstIndex(where: { $0.text == text }) else { return }
        queuedPromptsBySession[sessionID]?.remove(at: index)
        if queuedPromptsBySession[sessionID]?.isEmpty == true { queuedPromptsBySession.removeValue(forKey: sessionID) }
    }

    private func reduceSessionCreationResponse(
        _ payload: JSONValue,
        requestID: String,
        request: SessionCreationRequest
    ) async {
        switch request {
        case .workspaces:
            isLoadingWorkspaces = false
            guard let response: WorkspaceListCommandResponse = decode(payload), response.ok,
                  let result = response.result else {
                sessionCreationError = commandResponseError(payload)
                return
            }
            workspaceHome = result.home
            registeredWorkspaces = result.workspaces
            await browseWorkspace(result.home)
        case .browse:
            guard latestWorkspaceBrowseRequestID == requestID else { return }
            isBrowsingWorkspace = false
            guard let response: WorkspaceBrowseCommandResponse = decode(payload), response.ok,
                  let result = response.result else {
                sessionCreationError = commandResponseError(payload)
                return
            }
            workspaceDirectory = WorkspaceDirectoryListing(
                path: result.path,
                parent: result.parent,
                directories: result.directories
            )
        case .create(let path, let provider):
            isCreatingSession = false
            guard let response: SessionCreateCommandResponse = decode(payload), response.ok,
                  let result = response.result else {
                startingSessionPath = nil
                startingSessionPaneID = nil
                sessionCreationError = commandResponseError(payload)
                return
            }
            startingSessionPath = path
            startingSessionPaneID = result.paneID
            registeredWorkspaces = Array(Set(registeredWorkspaces + [path])).sorted()
            sessionCreationSucceeded = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(25))
                guard let self, self.startingSessionPaneID == result.paneID else { return }
                self.startingSessionPath = nil
                self.startingSessionPaneID = nil
                self.commandError = "The new \(provider.displayName) session did not finish starting."
            }
        }
    }

    private func commandResponseError(_ payload: JSONValue) -> String {
        if case .object(let response) = payload,
           case .object(let result) = response["result"],
           case .string(let error) = result["error"] {
            return error
        }
        return "The Vipi host rejected the request."
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
            isStreaming: true
        )
        messagesBySession[sessionID, default: []].append(pending)
    }

    func handle(_ envelope: ServerEnvelope) async {
        // Typed event reducers are intentionally centralized here. The host
        // protocol can evolve without coupling wire payloads to SwiftUI views.
        if envelope.type == "auth.ok" {
            connectionState = .connected
            if let payload = envelope.payload, let snapshot: ProviderSnapshot = decode(payload) {
                applyProviderSnapshot(snapshot)
            }
            UserDefaults.standard.set(host, forKey: "vipi.host")
            persistSimulatorToken(token)
            await registerPushDeviceIfAvailable()
            return
        }
        if envelope.type == "providers.snapshot", let payload = envelope.payload,
           let snapshot: ProviderSnapshot = decode(payload) {
            applyProviderSnapshot(snapshot)
            return
        }
        if envelope.type == "auth.rotated",
           case .object(let payload) = envelope.payload,
           case .string(let rotatedToken) = payload["token"] {
            token = rotatedToken
            await broker.updateToken(rotatedToken)
            try? KeychainStore.saveToken(rotatedToken)
            persistSimulatorToken(rotatedToken)
            return
        }
        if envelope.type == "sessions.snapshot", let payload = envelope.payload {
            do {
                let data = try JSONEncoder().encode(payload)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let snapshot = try decoder.decode(SessionSnapshot.self, from: data)
                if snapshot.replayReset == true {
                    lastEntryBySession.removeAll()
                    lastMessageAtBySession.removeAll()
                    oldestEntryBySession.removeAll()
                    historyHasMoreBySession.removeAll()
                    pendingHistoryRequests.removeAll()
                    historyRequestsInFlight.removeAll()
                }
                sessions = snapshot.sessions.map { session in
                    guard let lastMessageAt = lastMessageAtBySession[session.id] else { return session }
                    var updated = session
                    updated.lastActivityAt = lastMessageAt
                    return updated
                }
                if let selectedSessionID,
                   sessions.first(where: { $0.id == selectedSessionID })?.unread == true {
                    await markRead(selectedSessionID)
                }
                let workingSessionIDs = Set(sessions.filter { $0.phase == .working }.map(\.id))
                progressBySession = progressBySession.filter { workingSessionIDs.contains($0.key) }
                if let paneID = startingSessionPaneID,
                   sessions.contains(where: { $0.tmux.paneID == paneID }) {
                    startingSessionPath = nil
                    startingSessionPaneID = nil
                }
                scheduleLocalCacheSave()
            } catch {
                connectionState = .disconnected("Invalid session snapshot")
            }
            return
        }
        if envelope.type == "session.event", let payload = envelope.payload {
            reduceSessionEvent(payload)
            return
        }
        if envelope.type == "session.interaction", let payload = envelope.payload,
           let interaction: RemoteInteraction = decode(payload) {
            guard !pendingInteractions.contains(where: { $0.requestID == interaction.requestID }) else { return }
            pendingInteractions.append(interaction)
            if let index = sessions.firstIndex(where: { $0.id == interaction.sessionID }) {
                sessions[index].phase = .waitingForInput
            }
            return
        }
        if envelope.type == "session.response", let payload = envelope.payload {
            if let id = envelope.id, pendingPushRequests.remove(id) != nil {
                guard let response: PushCommandResponse = decode(payload), response.ok,
                      let result = response.result else {
                    pushRegistrationError = commandResponseError(payload)
                    return
                }
                pushHostConfigured = result.configured
                pushRegisteredDevices = result.devices
                pushRegistrationError = nil
                return
            }
            if let id = envelope.id,
               let request = pendingSessionCreationRequests.removeValue(forKey: id) {
                await reduceSessionCreationResponse(payload, requestID: id, request: request)
                return
            }
            if let id = envelope.id, let request = pendingHistoryRequests.removeValue(forKey: id) {
                reduceHistoryResponse(payload, request: request)
                historyRequestsInFlight.remove(request.sessionID)
                return
            }
            if case .object(let response) = payload,
               case .bool(false) = response["ok"] {
                if case .object(let result) = response["result"],
                   case .string(let error) = result["error"] {
                    commandError = error
                } else {
                    commandError = "The host rejected the command."
                }
            }
            return
        }
        if envelope.type == "error", case .object(let payload) = envelope.payload,
           case .string(let code) = payload["code"] {
            if let id = envelope.id, pendingPushRequests.remove(id) != nil {
                pushRegistrationError = code
                return
            }
            if let id = envelope.id,
               let request = pendingSessionCreationRequests.removeValue(forKey: id) {
                switch request {
                case .workspaces: isLoadingWorkspaces = false
                case .browse: isBrowsingWorkspace = false
                case .create:
                    isCreatingSession = false
                    startingSessionPath = nil
                }
                sessionCreationError = code
                return
            }
            if let id = envelope.id, let request = pendingHistoryRequests.removeValue(forKey: id) {
                historyRequestsInFlight.remove(request.sessionID)
            }
            if code == "SESSION_OFFLINE", case .string(let sessionID) = payload["sessionID"] {
                if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
                    sessions[index].phase = .offline
                }
            } else {
                commandError = code
            }
        }
    }

    private func applyProviderSnapshot(_ snapshot: ProviderSnapshot) {
        guard let codex = snapshot.providers.first(where: { $0.id == .codex }) else { return }
        switch codex.state {
        case "connected": codexConnectionState = .connected
        case "connecting": codexConnectionState = .connecting
        default: codexConnectionState = .disconnected(codex.detail)
        }
    }

    private func persistSimulatorToken(_ value: String) {
        #if targetEnvironment(simulator)
        // Simulator-only fallback keeps live development pairing across app
        // relaunches. Physical-device builds remain Keychain-only.
        UserDefaults.standard.set(value, forKey: "vipi.simulatorToken")
        #endif
    }
}

private struct ProviderSnapshot: Decodable {
    let providers: [ProviderStatus]
}

private struct ProviderStatus: Decodable {
    let id: AgentProvider
    let state: String
    let detail: String?
}

private struct PushCommandResponse: Decodable {
    let ok: Bool
    let result: PushCommandResult?
}

private struct PushCommandResult: Decodable {
    let configured: Bool
    let devices: Int
    let topic: String
}

private struct WorkspaceListCommandResponse: Decodable {
    let ok: Bool
    let result: WorkspaceListResult?
}

private struct WorkspaceListResult: Decodable {
    let home: String
    let workspaces: [String]
}

private struct WorkspaceBrowseCommandResponse: Decodable {
    let ok: Bool
    let result: WorkspaceBrowseResult?
}

private struct WorkspaceBrowseResult: Decodable {
    let path: String
    let parent: String?
    let directories: [String]
}

private struct SessionCreateCommandResponse: Decodable {
    let ok: Bool
    let result: SessionCreateResult?
}

private struct SessionCreateResult: Decodable {
    let cwd: String
    let paneID: String
}

private struct PersistedMobileCache: Codable {
    let savedAt: Date
    let sessions: [RemoteSession]
    let messagesBySession: [String: [ChatMessage]]
    let lastEntryBySession: [String: String]
    let oldestEntryBySession: [String: String]
    let historyHasMoreBySession: [String: Bool]
}

private struct SessionSnapshot: Decodable {
    let sessions: [RemoteSession]
    let replayReset: Bool?
}

private enum HistoryDirection {
    case initial, older, incremental
}

private struct PendingHistoryRequest {
    let sessionID: String
    let direction: HistoryDirection
}

private struct HistoryPayload: Encodable {
    let sessionID: String
    let afterEntryID: String?
    let beforeEntryID: String?
    let limit: Int
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
    let oldestEntryID: String?
    let hasMore: Bool?
}

private struct NormalizedEvent: Decodable {
    let kind: String
    let messageID: String?
    let role: ChatRole?
    let text: String?
    let timestamp: Date?
    let streaming: Bool?
    let entryID: String?
    let replacesMessageID: String?
    let attachments: [ChatImageAttachment]?
    let activity: ProgressActivity?
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

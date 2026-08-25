import SwiftUI

struct ChatView: View {
    @Environment(AppStore.self) private var store
    let sessionID: String
    @State private var showDetails = false
    @State private var showBranches = false
    @State private var focusedAssistantID: String?
    @State private var userHasScrolledTranscript = false
    @State private var isFollowingLatest = true
    @State private var isNavigatingHistory = false

    private var session: RemoteSession? { store.session(id: sessionID) }
    private var isWorking: Bool { session?.phase == .working }

    private var displayMessages: [ChatMessage] {
        let messages = store.messages(for: sessionID).filter { $0.role != .system }
        guard isWorking, let latestUserIndex = messages.lastIndex(where: { $0.role == .user }) else { return messages }
        return messages.enumerated().compactMap { index, message in
            index > latestUserIndex && message.role == .assistant ? nil : message
        }
    }

    var body: some View {
        ZStack {
            VipiBackdrop()
            transcript
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerView(
                draft: draftBinding,
                phase: session?.phase ?? .offline,
                queuedPrompts: store.queuedPrompts(for: sessionID)
            ) { mode in
                let text = store.draft(for: sessionID).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                store.setDraft("", for: sessionID)
                Task { await store.send(text: text, to: sessionID, delivery: mode) }
            } onStop: {
                Task { await store.abort(sessionID: sessionID) }
            }
        }
        .navigationTitle(session?.name.components(separatedBy: " / ").last ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Session details", systemImage: "info.circle") { showDetails = true }
                    Button("Conversation branches", systemImage: "arrow.triangle.branch") { showBranches = true }
                    Button("Compact context", systemImage: "arrow.down.right.and.arrow.up.left") {
                        Task { await store.compact(sessionID: sessionID) }
                    }
                    .accessibilityIdentifier("chat.compact")
                    Divider()
                    Button("Stop current run", systemImage: "stop.circle", role: .destructive) {
                        Task { await store.abort(sessionID: sessionID) }
                    }
                    .accessibilityIdentifier("chat.abort")
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 34, height: 34)
                        .vipiGlass(interactive: true, in: Circle())
                }
                .accessibilityIdentifier("chat.menu")
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            store.markRead(sessionID)
            Task { await store.ensureHistory(for: sessionID) }
        }
        .alert("Command failed", isPresented: commandErrorPresented) {
            Button("OK") { store.commandError = nil }
        } message: {
            Text(store.commandError ?? "Unknown transport error")
        }
        .sheet(isPresented: $showDetails) {
            if let session { SessionDetailsSheet(session: session) }
        }
        .sheet(isPresented: $showBranches) {
            BranchesSheet(nodes: store.branches(for: sessionID))
        }
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { store.draft(for: sessionID) },
            set: { store.setDraft($0, for: sessionID) }
        )
    }

    private var commandErrorPresented: Binding<Bool> {
        Binding(
            get: { store.commandError != nil },
            set: { if !$0 { store.commandError = nil } }
        )
    }

    @ViewBuilder
    private var transcript: some View {
        if store.isHistoryLoading(for: sessionID) && store.messages(for: sessionID).isEmpty {
            ChatLoadingView()
                .accessibilityIdentifier("chat.loading")
        } else {
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        VStack(spacing: 20) {
                            if store.canLoadOlderHistory(for: sessionID) {
                                OlderHistoryLoader(isLoading: store.isHistoryLoading(for: sessionID))
                                    .onAppear {
                                        guard userHasScrolledTranscript, !isNavigatingHistory else { return }
                                        let anchor = displayMessages.first?.id
                                        Task {
                                            await store.loadOlderHistory(for: sessionID)
                                            if let anchor { proxy.scrollTo(rowID(for: anchor), anchor: .top) }
                                        }
                                    }
                            }
                            ForEach(displayMessages) { message in
                                ChatMessageRow(message: message)
                                    .id(rowID(for: message.id))
                            }
                            if isWorking {
                                WorkingStatusView(
                                    activity: store.progressActivity(for: sessionID),
                                    startedAt: displayMessages.last(where: { $0.role == .user })?.timestamp ?? .now
                                )
                                .id("working-status")
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .accessibilityIdentifier("chat.transcript")
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting {
                            userHasScrolledTranscript = true
                            isFollowingLatest = false
                        }
                    }
                    .onChange(of: latestTranscriptRevision) {
                        guard !store.isHistoryLoading(for: sessionID), isFollowingLatest else { return }
                        focusedAssistantID = assistantMessageIDs.last
                        scrollToLatestContent(using: proxy)
                    }

                    if !assistantMessageIDs.isEmpty || store.canLoadOlderHistory(for: sessionID) {
                        MessageNavigationControls(
                            goUp: { Task { await focusPreviousAssistant(using: proxy) } },
                            goDown: { focusNextAssistant(using: proxy) }
                        )
                        .padding(.trailing, 12)
                        .padding(.bottom, 10)
                    }
                }
                .onAppear {
                    focusedAssistantID = assistantMessageIDs.last
                    scrollToLatestContent(using: proxy)
                }
            }
        }
    }

    private var assistantMessageIDs: [String] {
        displayMessages
            .filter { $0.role == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.id)
    }

    private func rowID(for messageID: String) -> String { "message-\(messageID)" }

    private var latestTranscriptRevision: String {
        let last = displayMessages.last.map { "\($0.id):\($0.text):\($0.isStreaming)" } ?? "empty"
        return "\(last):\(isWorking):\(store.progressActivity(for: sessionID).rawValue)"
    }

    private func focusPreviousAssistant(using proxy: ScrollViewProxy) async {
        var ids = assistantMessageIDs
        isFollowingLatest = false
        userHasScrolledTranscript = true
        isNavigatingHistory = true
        let currentID = focusedAssistantID.flatMap { ids.contains($0) ? $0 : nil }
        var currentIndex = currentID.flatMap { ids.firstIndex(of: $0) } ?? ids.count

        for _ in 0..<8 {
            guard (ids.isEmpty || currentIndex == 0), store.canLoadOlderHistory(for: sessionID) else { break }
            await store.loadOlderHistory(for: sessionID)
            for _ in 0..<120 where store.isHistoryLoading(for: sessionID) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            ids = assistantMessageIDs
            currentIndex = currentID.flatMap { ids.firstIndex(of: $0) } ?? ids.count
        }

        guard currentIndex > 0, !ids.isEmpty else {
            isNavigatingHistory = false
            return
        }
        let targetID = ids[currentIndex - 1]
        focusedAssistantID = targetID
        withAnimation(.snappy) { proxy.scrollTo(rowID(for: targetID), anchor: .top) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            isNavigatingHistory = false
        }
    }

    private func focusNextAssistant(using proxy: ScrollViewProxy) {
        let ids = assistantMessageIDs
        guard !ids.isEmpty else { return }
        userHasScrolledTranscript = true
        let currentIndex = focusedAssistantID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let targetIndex = min(ids.count - 1, currentIndex + 1)
        focusedAssistantID = ids[targetIndex]
        isFollowingLatest = targetIndex == ids.count - 1
        withAnimation(.snappy) { proxy.scrollTo(rowID(for: ids[targetIndex]), anchor: .top) }
    }

    private func scrollToLatestContent(using proxy: ScrollViewProxy) {
        let target = isWorking ? "working-status" : displayMessages.last.map { rowID(for: $0.id) }
        guard let target else { return }
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(120))
            proxy.scrollTo(target, anchor: .bottom)
        }
    }
}

private struct OlderHistoryLoader: View {
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isLoading { ProgressView().controlSize(.small) }
            Text(isLoading ? "이전 메시지를 불러오는 중…" : "위로 스크롤해 이전 메시지 보기")
                .font(.caption)
                .foregroundStyle(VipiTheme.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .accessibilityIdentifier("chat.olderHistory")
    }
}

private struct MessageNavigationControls: View {
    let goUp: () -> Void
    let goDown: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: goUp) {
                Image(systemName: "chevron.up")
                    .frame(width: 38, height: 34)
            }
            .accessibilityIdentifier("chat.previousAssistantMessage")
            .accessibilityLabel("이전 어시스턴트 메시지")
            Divider().overlay(VipiTheme.stroke).padding(.horizontal, 8)
            Button(action: goDown) {
                Image(systemName: "chevron.down")
                    .frame(width: 38, height: 34)
            }
            .accessibilityIdentifier("chat.nextAssistantMessage")
            .accessibilityLabel("다음 어시스턴트 메시지")
        }
        .font(.subheadline.bold())
        .foregroundStyle(VipiTheme.primary)
        .frame(width: 42)
        .vipiGlass(interactive: true, in: Capsule())
    }
}

private struct ChatLoadingView: View {
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 22) {
            loadingBubble(width: 0.72, alignment: .trailing)
            loadingBubble(width: 0.9, alignment: .leading)
            loadingBubble(width: 0.58, alignment: .trailing)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .opacity(pulse ? 0.42 : 0.78)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityLabel("대화를 불러오는 중")
    }

    private func loadingBubble(width: CGFloat, alignment: Alignment) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Capsule().fill(VipiTheme.stroke).frame(width: 82, height: 10)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.thinMaterial)
                .frame(maxWidth: .infinity, minHeight: 72)
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .frame(width: UIScreen.main.bounds.width * width)
    }
}

private struct ChatMessageRow: View {
    let message: ChatMessage

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 44)
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .vipiGlass(tint: VipiTheme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        } else {
            Text(.init(message.text))
                .font(.body)
                .foregroundStyle(VipiTheme.primary)
                .textSelection(.enabled)
                .accessibilityIdentifier("assistant.message.\(message.id)")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct WorkingStatusView: View {
    let activity: ProgressActivity
    let startedAt: Date
    @State private var pulse = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(VipiTheme.stroke, lineWidth: 1)
                        .frame(width: 24, height: 24)
                    Circle()
                        .fill(VipiTheme.accent)
                        .frame(width: 7, height: 7)
                        .scaleEffect(pulse ? 1.0 : 0.55)
                        .opacity(pulse ? 1 : 0.45)
                        .shadow(color: VipiTheme.accent.opacity(0.55), radius: 5)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(activity.title)…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(VipiTheme.primary)
                    Text(elapsedText(at: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(VipiTheme.secondary)
                }
                Spacer()
                Text("●")
                    .font(.caption2.monospaced())
                    .foregroundStyle(VipiTheme.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(VipiTheme.stroke, lineWidth: 0.75)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat.progress")
            .accessibilityLabel(activity.title)
            .accessibilityValue(elapsedText(at: context.date))
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private func elapsedText(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(startedAt)))
        if seconds < 60 { return "\(seconds)초 작업 중" }
        return "\(seconds / 60)분 \(seconds % 60)초 작업 중"
    }
}

import SwiftUI

struct ChatView: View {
    @Environment(AppStore.self) private var store
    let sessionID: String
    @State private var showDetails = false
    @State private var showBranches = false
    @State private var focusedAssistantID: String?
    @State private var userHasScrolledTranscript = false

    private var session: RemoteSession? { store.session(id: sessionID) }

    var body: some View {
        ZStack {
            VipiBackdrop()
            transcript
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerView(draft: draftBinding, phase: session?.phase ?? .offline) { mode in
                let text = store.draft(for: sessionID).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                store.setDraft("", for: sessionID)
                Task { await store.send(text: text, to: sessionID, delivery: mode) }
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
                        LazyVStack(spacing: 20) {
                            if store.canLoadOlderHistory(for: sessionID) {
                                OlderHistoryLoader(isLoading: store.isHistoryLoading(for: sessionID))
                                    .onAppear {
                                        guard userHasScrolledTranscript else { return }
                                        let anchor = store.messages(for: sessionID).first?.id
                                        Task {
                                            await store.loadOlderHistory(for: sessionID)
                                            if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                                        }
                                    }
                            }
                            ForEach(store.messages(for: sessionID)) { message in
                                MessageView(message: message).id(message.id)
                            }
                            Color.clear.frame(height: 4).id("bottom")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .accessibilityIdentifier("chat.transcript")
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting { userHasScrolledTranscript = true }
                    }
                    .onChange(of: store.messages(for: sessionID).count) {
                        guard !store.isHistoryLoading(for: sessionID) else { return }
                        focusedAssistantID = assistantMessageIDs.last
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }

                    if !assistantMessageIDs.isEmpty {
                        MessageNavigationControls(
                            goUp: { focusPreviousAssistant(using: proxy) },
                            goDown: { focusLatestAssistant(using: proxy) }
                        )
                        .padding(.trailing, 12)
                        .padding(.bottom, 10)
                    }
                }
                .onAppear {
                    focusedAssistantID = assistantMessageIDs.last
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var assistantMessageIDs: [String] {
        store.messages(for: sessionID).filter { $0.role == .assistant }.map(\.id)
    }

    private func focusPreviousAssistant(using proxy: ScrollViewProxy) {
        let ids = assistantMessageIDs
        guard !ids.isEmpty else { return }
        let currentIndex = focusedAssistantID.flatMap { ids.firstIndex(of: $0) } ?? ids.count - 1
        let targetIndex = max(0, currentIndex - 1)
        focusedAssistantID = ids[targetIndex]
        withAnimation(.snappy) { proxy.scrollTo(ids[targetIndex], anchor: .top) }
    }

    private func focusLatestAssistant(using proxy: ScrollViewProxy) {
        guard let latest = assistantMessageIDs.last else { return }
        focusedAssistantID = latest
        withAnimation(.snappy) { proxy.scrollTo(latest, anchor: .top) }
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
            .accessibilityIdentifier("chat.previousPiMessage")
            .accessibilityLabel("이전 Pi 메시지")
            Divider().overlay(VipiTheme.stroke).padding(.horizontal, 8)
            Button(action: goDown) {
                Image(systemName: "chevron.down")
                    .frame(width: 38, height: 34)
            }
            .accessibilityIdentifier("chat.latestPiMessage")
            .accessibilityLabel("최신 Pi 메시지")
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
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                pulse = true
            }
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

private struct MessageView: View {
    let message: ChatMessage

    var body: some View {
        if message.role == .user {
            HStack { Spacer(minLength: 44); Text(message.text)
                .font(.body).foregroundStyle(.white)
                .padding(.horizontal, 15).padding(.vertical, 11)
                .vipiGlass(tint: VipiTheme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "circle.hexagongrid.fill").foregroundStyle(VipiTheme.accent)
                    Text("Pi").font(.subheadline.bold())
                    if message.isStreaming { ProgressView().controlSize(.small).tint(VipiTheme.accent) }
                    Spacer()
                    Text(message.timestamp, style: .time).font(.caption2).foregroundStyle(VipiTheme.secondary)
                }
                Text(.init(message.text))
                    .font(.body).foregroundStyle(VipiTheme.primary)
                    .textSelection(.enabled)
                ForEach(message.tools) { tool in ToolCard(tool: tool) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ToolCard: View {
    let tool: ToolActivity
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(color)
                    Text(tool.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(VipiTheme.primary)
                    Spacer()
                    if let changed = tool.changedFiles {
                        Text("\(changed) files")
                            .font(.caption2)
                            .foregroundStyle(VipiTheme.secondary)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(VipiTheme.secondary)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tool \(tool.name)")
            .accessibilityValue("\(tool.state.rawValue), \(tool.summary)")
            .accessibilityHint(expanded ? "Collapses tool details" : "Expands tool details")

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tool.summary)
                    if let detail = tool.detail, detail != tool.summary {
                        Text(detail)
                    }
                }
                .font(.caption.monospaced())
                .foregroundStyle(VipiTheme.secondary)
                .textSelection(.enabled)
                .padding(.bottom, 10)
            }

            Divider().overlay(VipiTheme.stroke)
        }
    }

    private var icon: String { tool.state == .running ? "gearshape.2.fill" : tool.state == .failed ? "xmark.circle.fill" : "checkmark.circle.fill" }
    private var color: Color { tool.state == .running ? VipiTheme.accent : tool.state == .failed ? VipiTheme.danger : VipiTheme.success }
}

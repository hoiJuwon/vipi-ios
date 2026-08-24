import SwiftUI

struct ChatView: View {
    @Environment(AppStore.self) private var store
    let sessionID: String
    @State private var draft = ""
    @State private var showDetails = false
    @State private var showBranches = false
    @State private var delivery: PromptDelivery = .prompt

    private var session: RemoteSession? { store.session(id: sessionID) }

    var body: some View {
        ZStack {
            VipiTheme.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                if let session { SessionContextBar(session: session) }
                transcript
                ComposerView(draft: $draft, phase: session?.phase ?? .offline) { mode in
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    draft = ""
                    Task { await store.send(text: text, to: sessionID, delivery: mode) }
                }
            }
        }
        .navigationTitle(session?.name.components(separatedBy: " / ").last ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Session details", systemImage: "info.circle") { showDetails = true }
                    Button("Conversation branches", systemImage: "arrow.triangle.branch") { showBranches = true }
                    Button("Compact context", systemImage: "arrow.down.right.and.arrow.up.left") { }
                    Divider()
                    Button("Stop current run", systemImage: "stop.circle", role: .destructive) {
                        Task { await store.abort(sessionID: sessionID) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear { store.markRead(sessionID) }
        .sheet(isPresented: $showDetails) {
            if let session { SessionDetailsSheet(session: session) }
        }
        .sheet(isPresented: $showBranches) {
            BranchesSheet(nodes: store.branches(for: sessionID))
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 20) {
                    ForEach(store.messages(for: sessionID)) { message in
                        MessageView(message: message).id(message.id)
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.messages(for: sessionID).count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

private struct SessionContextBar: View {
    let session: RemoteSession

    var body: some View {
        HStack(spacing: 10) {
            StatusPill(phase: session.phase)
            Text(session.model).font(.caption.weight(.medium))
            Text("·").foregroundStyle(VipiTheme.secondary)
            Text(session.thinkingLevel).font(.caption)
            Spacer()
            Gauge(value: Double(session.contextPercent), in: 0...100) { EmptyView() }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(session.contextPercent > 80 ? VipiTheme.warning : VipiTheme.accent)
                .frame(width: 22, height: 22)
            Text("\(session.contextPercent)%").font(.caption2.monospacedDigit())
        }
        .foregroundStyle(VipiTheme.secondary)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider().overlay(VipiTheme.stroke) }
    }
}

private struct MessageView: View {
    let message: ChatMessage

    var body: some View {
        if message.role == .user {
            HStack { Spacer(minLength: 44); Text(message.text)
                .font(.body).foregroundStyle(.white)
                .padding(.horizontal, 15).padding(.vertical, 11)
                .background(VipiTheme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
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
        Button { withAnimation(.snappy) { expanded.toggle() } } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    Image(systemName: icon).foregroundStyle(color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name).font(.caption.bold()).foregroundStyle(VipiTheme.primary)
                        Text(tool.summary).font(.caption).foregroundStyle(VipiTheme.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let changed = tool.changedFiles {
                        Text("\(changed) files").font(.caption2).foregroundStyle(VipiTheme.secondary)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.bold()).foregroundStyle(VipiTheme.secondary)
                }
                if expanded, let detail = tool.detail {
                    Divider().overlay(VipiTheme.stroke)
                    Text(detail).font(.caption.monospaced()).foregroundStyle(VipiTheme.secondary)
                }
            }
            .padding(12)
            .background(VipiTheme.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(VipiTheme.stroke) }
        }
        .buttonStyle(.plain)
    }

    private var icon: String { tool.state == .running ? "gearshape.2.fill" : tool.state == .failed ? "xmark.circle.fill" : "checkmark.circle.fill" }
    private var color: Color { tool.state == .running ? VipiTheme.accent : tool.state == .failed ? VipiTheme.danger : VipiTheme.success }
}

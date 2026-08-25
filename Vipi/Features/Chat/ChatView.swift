import SwiftUI
import UIKit

struct ChatView: View {
    @Environment(AppStore.self) private var store
    let sessionID: String
    @State private var showDetails = false
    @State private var showBranches = false
    @State private var focusedAssistantID: String?
    @State private var userHasScrolledTranscript = false
    @State private var isFollowingLatest = true
    @State private var isNavigatingHistory = false
    @State private var pinsSubmittedTurn = false

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
                queuedPrompts: store.queuedPrompts(for: sessionID),
                annotations: store.annotations(for: sessionID),
                onRemoveAnnotation: { store.removeAnnotation($0, from: sessionID) }
            ) { mode in
                let text = store.draft(for: sessionID).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                store.setDraft("", for: sessionID)
                if mode == .prompt {
                    pinsSubmittedTurn = true
                    isFollowingLatest = true
                    userHasScrolledTranscript = false
                }
                let annotations = store.annotations(for: sessionID)
                Task {
                    let sent = await store.send(text: text, annotations: annotations, to: sessionID, delivery: mode)
                    if sent {
                        store.clearAnnotations(for: sessionID)
                    } else if mode == .prompt {
                        pinsSubmittedTurn = false
                    }
                }
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
            store.selectedSessionID = sessionID
            Task {
                await store.markRead(sessionID)
                await store.ensureHistory(for: sessionID)
            }
        }
        .onDisappear {
            if store.selectedSessionID == sessionID { store.selectedSessionID = nil }
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
                                ChatMessageRow(message: message) { excerpt in
                                    store.addAnnotation(messageID: message.id, text: excerpt, to: sessionID)
                                }
                                .id(rowID(for: message.id))
                            }
                            if isWorking {
                                WorkingStatusView(
                                    activity: store.progressActivity(for: sessionID),
                                    startedAt: displayMessages.last(where: { $0.role == .user })?.timestamp ?? .now
                                )
                                .id("working-status")
                            }
                            if isWorking || pinsSubmittedTurn {
                                Color.clear
                                    .containerRelativeFrame(.vertical) { length, _ in max(0, length - 72) }
                                    .accessibilityHidden(true)
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
                    .onChange(of: latestUserMessageID) {
                        guard isWorking || pinsSubmittedTurn else { return }
                        scrollToLatestContent(using: proxy)
                    }
                    .onChange(of: isWorking) {
                        if !isWorking { pinsSubmittedTurn = false }
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

    private var latestUserMessageID: String? {
        displayMessages.last(where: { $0.role == .user })?.id
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
        let pinsCurrentTurn = isWorking || pinsSubmittedTurn
        let target = pinsCurrentTurn ? latestUserMessageID.map(rowID(for:)) : displayMessages.last.map { rowID(for: $0.id) }
        guard let target else { return }
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.snappy) {
                proxy.scrollTo(target, anchor: pinsCurrentTurn ? .top : .bottom)
            }
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
    let onAddToChat: (String) -> Void

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 44)
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(VipiTheme.accentForeground)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .vipiGlass(tint: VipiTheme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        } else {
            MarkdownMessageView(source: message.text, messageID: message.id, onAddToChat: onAddToChat)
                .foregroundStyle(VipiTheme.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum MobileMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedItem(marker: String, text: String)
    case orderedItem(number: String, text: String)
    case quote(String)
    case code(language: String?, text: String)
    case divider
}

enum MobileMarkdownParser {
    static func parse(_ source: String) -> [MobileMarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MobileMarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, text: codeLines.joined(separator: "\n")))
            } else if trimmed.isEmpty {
                flushParagraph()
            } else if let heading = heading(from: trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
            } else if ["---", "***", "___"].contains(trimmed) {
                flushParagraph()
                blocks.append(.divider)
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                let value = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                blocks.append(.quote(value))
            } else if let item = unorderedItem(from: trimmed) {
                flushParagraph()
                blocks.append(.unorderedItem(marker: item.marker, text: item.text))
            } else if let item = orderedItem(from: trimmed) {
                flushParagraph()
                blocks.append(.orderedItem(number: item.number, text: item.text))
            } else {
                paragraph.append(line)
            }
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let level = min(line.prefix(while: { $0 == "#" }).count, 6)
        guard level > 0 else { return nil }
        let boundary = line.index(line.startIndex, offsetBy: level)
        guard boundary < line.endIndex, line[boundary].isWhitespace else { return nil }
        return (level, String(line[boundary...]).trimmingCharacters(in: .whitespaces))
    }

    private static func unorderedItem(from line: String) -> (marker: String, text: String)? {
        guard line.count >= 2, ["- ", "* ", "+ "].contains(String(line.prefix(2))) else { return nil }
        var text = String(line.dropFirst(2))
        var marker = "•"
        if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
            marker = "checkmark.square.fill"
            text = String(text.dropFirst(4))
        } else if text.hasPrefix("[ ] ") {
            marker = "square"
            text = String(text.dropFirst(4))
        }
        return (marker, text)
    }

    private static func orderedItem(from line: String) -> (number: String, text: String)? {
        guard let dot = line.firstIndex(of: "."), dot < line.index(before: line.endIndex) else { return nil }
        let number = String(line[..<dot])
        guard !number.isEmpty, number.allSatisfy(\.isNumber), line[line.index(after: dot)].isWhitespace else { return nil }
        return (number + ".", String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces))
    }
}

private struct MarkdownMessageView: View {
    let source: String
    let messageID: String
    let onAddToChat: (String) -> Void

    private var blocks: [MobileMarkdownBlock] { MobileMarkdownParser.parse(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, isAnchor: index == 0)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func blockView(_ block: MobileMarkdownBlock, isAnchor: Bool) -> some View {
        switch block {
        case let .heading(level, text):
            inlineText(text, style: .heading(level))
                .padding(.top, level <= 2 ? 4 : 1)
                .messageAnchor(isAnchor ? "assistant.message.\(messageID)" : nil)
        case let .paragraph(text):
            inlineText(text, style: .body)
                .messageAnchor(isAnchor ? "assistant.message.\(messageID)" : nil)
        case let .unorderedItem(marker, text):
            HStack(alignment: .top, spacing: 9) {
                if marker == "•" {
                    Text("•").font(.body.weight(.semibold)).padding(.top, 1)
                } else {
                    Image(systemName: marker).font(.caption.weight(.semibold)).foregroundStyle(VipiTheme.accent).padding(.top, 3)
                }
                inlineText(text, style: .body)
                    .messageAnchor(isAnchor ? "assistant.message.\(messageID)" : nil)
            }
            .padding(.leading, 4)
        case let .orderedItem(number, text):
            HStack(alignment: .top, spacing: 8) {
                Text(number).font(.body.monospacedDigit()).foregroundStyle(VipiTheme.secondary).padding(.top, 1)
                inlineText(text, style: .body)
                    .messageAnchor(isAnchor ? "assistant.message.\(messageID)" : nil)
            }
            .padding(.leading, 4)
        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(VipiTheme.accent.opacity(0.65)).frame(width: 3)
                inlineText(text, style: .quote)
                    .messageAnchor(isAnchor ? "assistant.message.\(messageID)" : nil)
            }
        case let .code(language, text):
            VStack(alignment: .leading, spacing: 7) {
                if let language {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(VipiTheme.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(verbatim: text)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .messageAnchor(isAnchor ? "assistant.message.\(messageID)" : nil)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(VipiTheme.stroke, lineWidth: 0.75)
            }
        case .divider:
            Divider().overlay(VipiTheme.stroke).padding(.vertical, 3)
        }
    }

    private func inlineText(_ source: String, style: SelectableAssistantText.Style) -> some View {
        SelectableAssistantText(source: source, style: style, onAddToChat: onAddToChat)
    }
}

private struct SelectableAssistantText: UIViewRepresentable {
    enum Style: Equatable {
        case body
        case heading(Int)
        case quote

        var baseFont: UIFont {
            switch self {
            case .body, .quote:
                UIFont.preferredFont(forTextStyle: .body)
            case .heading(1):
                UIFont.preferredFont(forTextStyle: .title3).withTraits(.traitBold)
            case .heading(2):
                UIFont.preferredFont(forTextStyle: .headline).withTraits(.traitBold)
            case .heading(3):
                UIFont.preferredFont(forTextStyle: .body).withTraits(.traitBold)
            case .heading:
                UIFont.preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
            }
        }

        var color: UIColor {
            switch self {
            case .quote: .secondaryLabel
            default: .label
            }
        }
    }

    let source: String
    let style: Style
    let onAddToChat: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.linkTextAttributes = [.foregroundColor: UIColor.systemBlue]
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        let attributed = Self.makeAttributedText(source, style: style)
        if textView.attributedText != attributed { textView.attributedText = attributed }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    private static func makeAttributedText(_ source: String, style: Style) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return NSAttributedString(string: source, attributes: attributes(font: style.baseFont, color: style.color))
        }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            var font = style.baseFont
            if style == .quote { font = font.withTraits(.traitItalic) }
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { font = font.withTraits(.traitBold) }
                if intent.contains(.emphasized) { font = font.withTraits(.traitItalic) }
                if intent.contains(.code) { font = UIFont.monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular) }
            }
            var runAttributes = attributes(font: font, color: style.color)
            if let link = run.link { runAttributes[.link] = link }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: runAttributes))
        }
        return result
    }

    private static func attributes(font: UIFont, color: UIColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SelectableAssistantText

        init(parent: SelectableAssistantText) { self.parent = parent }

        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard range.length > 0, range.location != NSNotFound else { return UIMenu(children: suggestedActions) }
            let add = UIAction(title: "Add to Chat", image: UIImage(systemName: "plus.bubble")) { [weak textView, weak self] _ in
                guard let textView, let self else { return }
                let excerpt = (textView.text as NSString).substring(with: range)
                self.parent.onAddToChat(excerpt)
                textView.selectedRange = NSRange(location: NSMaxRange(range), length: 0)
                textView.resignFirstResponder()
            }
            return UIMenu(children: [add] + suggestedActions)
        }
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

private struct MessageAnchorModifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

private extension View {
    func messageAnchor(_ identifier: String?) -> some View {
        modifier(MessageAnchorModifier(identifier: identifier))
    }
}

private struct WorkingStatusView: View {
    let activity: ProgressActivity
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.45)) { context in
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.title + animatedDots(at: context.date))
                    .font(.body.italic())
                    .foregroundStyle(VipiTheme.primary)
                    .contentTransition(.interpolate)
                    .animation(.easeInOut(duration: 0.2), value: activity)
                Text(elapsedText(at: context.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(VipiTheme.secondary)
                LiquidOrbView()
                    .frame(width: 44, height: 44)
                    .offset(x: -11)
                    .frame(width: 27, height: 13, alignment: .leading)
                    .clipped()
                    .shadow(color: VipiTheme.accent.opacity(0.38), radius: 6)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat.progress")
            .accessibilityLabel(activity.title)
            .accessibilityValue(elapsedText(at: context.date))
        }
    }

    private func animatedDots(at date: Date) -> String {
        String(repeating: ".", count: Int(date.timeIntervalSinceReferenceDate / 0.45) % 3 + 1)
    }

    private func elapsedText(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(startedAt)))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}

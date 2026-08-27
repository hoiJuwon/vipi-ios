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
                imageAttachments: store.draftImages(for: sessionID),
                interaction: store.pendingInteractions.first(where: { $0.sessionID == sessionID }),
                interactionSessionName: session?.name,
                onRemoveAnnotation: { store.removeAnnotation($0, from: sessionID) },
                onAddImage: { store.addDraftImage($0, to: sessionID) },
                onRemoveImage: { store.removeDraftImage($0, from: sessionID) },
                onPhotoImportError: { store.commandError = $0 },
                onRespondToInteraction: { interaction, response in
                    Task { await store.respond(to: interaction, with: response) }
                }
            ) { mode in
                let text = store.draft(for: sessionID).trimmingCharacters(in: .whitespacesAndNewlines)
                let images = store.draftImages(for: sessionID)
                guard !text.isEmpty || !images.isEmpty else { return }
                store.setDraft("", for: sessionID)
                store.clearDraftImages(for: sessionID)
                if mode == .prompt {
                    pinsSubmittedTurn = true
                    isFollowingLatest = true
                    userHasScrolledTranscript = false
                }
                let annotations = store.annotations(for: sessionID)
                Task {
                    let sent = await store.send(
                        text: text,
                        annotations: annotations,
                        images: images,
                        to: sessionID,
                        delivery: mode
                    )
                    if sent {
                        store.clearAnnotations(for: sessionID)
                    } else {
                        if store.draft(for: sessionID).isEmpty { store.setDraft(text, for: sessionID) }
                        store.restoreDraftImages(images, for: sessionID)
                        if mode == .prompt { pinsSubmittedTurn = false }
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
                                .background {
                                    if message.role == .assistant {
                                        GeometryReader { geometry in
                                            Color.clear.preference(
                                                key: AssistantMessageOffsetKey.self,
                                                value: [message.id: geometry.frame(in: .named("chat-transcript")).minY]
                                            )
                                        }
                                    }
                                }
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
                    .coordinateSpace(name: "chat-transcript")
                    .scrollDismissesKeyboard(.interactively)
                    .accessibilityIdentifier("chat.transcript")
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting {
                            userHasScrolledTranscript = true
                            isFollowingLatest = false
                            isNavigatingHistory = false
                        }
                    }
                    .onPreferenceChange(AssistantMessageOffsetKey.self) { offsets in
                        guard userHasScrolledTranscript, !isNavigatingHistory else { return }
                        focusedAssistantID = assistantMessageIDs.min { lhs, rhs in
                            abs((offsets[lhs] ?? .greatestFiniteMagnitude) - 18) <
                                abs((offsets[rhs] ?? .greatestFiniteMagnitude) - 18)
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
        let last = displayMessages.last.map {
            "\($0.id):\($0.text):\($0.attachments.map(\.id).joined(separator: ",")):\($0.isStreaming)"
        } ?? "empty"
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
        isNavigatingHistory = true
        let currentIndex = focusedAssistantID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let targetIndex = min(ids.count - 1, currentIndex + 1)
        focusedAssistantID = ids[targetIndex]
        isFollowingLatest = targetIndex == ids.count - 1
        withAnimation(.snappy) { proxy.scrollTo(rowID(for: ids[targetIndex]), anchor: .top) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            isNavigatingHistory = false
        }
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

private struct AssistantMessageOffsetKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
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

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 8) {
                    navigationButton(
                        systemName: "chevron.up",
                        identifier: "chat.previousAssistantMessage",
                        label: "이전 어시스턴트 메시지",
                        action: goUp
                    )
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    navigationButton(
                        systemName: "chevron.down",
                        identifier: "chat.nextAssistantMessage",
                        label: "다음 어시스턴트 메시지",
                        action: goDown
                    )
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                }
            }
        } else {
            VStack(spacing: 0) {
                navigationButton(
                    systemName: "chevron.up",
                    identifier: "chat.previousAssistantMessage",
                    label: "이전 어시스턴트 메시지",
                    action: goUp
                )
                .frame(minWidth: 44, minHeight: 44)
                Divider().overlay(VipiTheme.stroke).padding(.horizontal, 8)
                navigationButton(
                    systemName: "chevron.down",
                    identifier: "chat.nextAssistantMessage",
                    label: "다음 어시스턴트 메시지",
                    action: goDown
                )
                .frame(minWidth: 44, minHeight: 44)
            }
            .vipiGlass(in: Capsule())
        }
    }

    private func navigationButton(
        systemName: String,
        identifier: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.subheadline.bold())
                .foregroundStyle(VipiTheme.primary)
                .frame(width: 20, height: 20)
        }
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
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
                VStack(alignment: .trailing, spacing: 8) {
                    if !message.attachments.isEmpty {
                        SentImageGrid(attachments: message.attachments)
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.body)
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, message.attachments.isEmpty ? 15 : 8)
                .padding(.vertical, message.attachments.isEmpty ? 11 : 8)
                .background(VipiTheme.userBubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        } else {
            MarkdownMessageView(source: message.text, messageID: message.id, onAddToChat: onAddToChat)
                .foregroundStyle(VipiTheme.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SentImageGrid: View {
    let attachments: [ChatImageAttachment]

    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
    ]

    var body: some View {
        LazyVGrid(columns: attachments.count == 1 ? [GridItem(.flexible())] : columns, spacing: 4) {
            ForEach(attachments) { attachment in
                Group {
                    if let data = ChatImageCache.data(for: attachment), let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            Color.white.opacity(0.08)
                            Image(systemName: "photo")
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }
                }
                .frame(width: attachments.count == 1 ? 220 : 106, height: attachments.count == 1 ? 180 : 106)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(attachments.count == 1 ? "1 attached photo" : "\(attachments.count) attached photos")
    }
}

enum MobileMarkdownTableAlignment: Equatable {
    case leading
    case center
    case trailing
}

struct MobileMarkdownTable: Equatable {
    let headers: [String]
    let alignments: [MobileMarkdownTableAlignment]
    let rows: [[String]]
}

enum MobileMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedItem(marker: String, text: String)
    case orderedItem(number: String, text: String)
    case quote(String)
    case code(language: String?, text: String)
    case table(MobileMarkdownTable)
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
            } else if let table = table(from: lines, startingAt: index) {
                flushParagraph()
                blocks.append(.table(table.value))
                index = table.lastLineIndex
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

    private static func table(
        from lines: [String],
        startingAt index: Int
    ) -> (value: MobileMarkdownTable, lastLineIndex: Int)? {
        guard index + 1 < lines.count,
              let headers = tableCells(from: lines[index]),
              let delimiter = tableCells(from: lines[index + 1]),
              headers.count == delimiter.count,
              headers.count >= 2
        else { return nil }

        let alignments = delimiter.compactMap { tableAlignment(from: $0) }
        guard alignments.count == headers.count else { return nil }

        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count, let cells = tableCells(from: lines[cursor]) {
            guard !lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty else { break }
            rows.append((0..<headers.count).map { $0 < cells.count ? cells[$0] : "" })
            cursor += 1
        }
        return (
            MobileMarkdownTable(headers: headers, alignments: alignments, rows: rows),
            cursor - 1
        )
    }

    private static func tableAlignment(from delimiter: String) -> MobileMarkdownTableAlignment? {
        let value = delimiter.trimmingCharacters(in: .whitespaces)
        let hasLeadingColon = value.hasPrefix(":")
        let hasTrailingColon = value.hasSuffix(":")
        let rule = value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard rule.count >= 3, rule.allSatisfy({ $0 == "-" }) else { return nil }
        if hasLeadingColon && hasTrailingColon { return .center }
        if hasTrailingColon { return .trailing }
        return .leading
    }

    private static func tableCells(from line: String) -> [String]? {
        var value = line.trimmingCharacters(in: .whitespaces)
        guard value.contains("|") else { return nil }
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }

        var cells: [String] = []
        var cell = ""
        var escaped = false
        var inCode = false
        for character in value {
            if escaped {
                cell.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                inCode.toggle()
                cell.append(character)
            } else if character == "|", !inCode {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells.count >= 2 ? cells : nil
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
        case let .table(table):
            MarkdownTableView(table: table, onAddToChat: onAddToChat)
                .messageAnchor(isAnchor ? "assistant.message.\(messageID)" : nil)
        case .divider:
            Divider().overlay(VipiTheme.stroke).padding(.vertical, 3)
        }
    }

    private func inlineText(_ source: String, style: SelectableAssistantText.Style) -> some View {
        SelectableAssistantText(source: source, style: style, onAddToChat: onAddToChat)
    }
}

private struct MarkdownTableView: View {
    let table: MobileMarkdownTable
    let onAddToChat: (String) -> Void

    private var columnWidths: [CGFloat] {
        let columns = table.headers.indices.map { index in
            [table.headers[index]] + table.rows.map { index < $0.count ? $0[index] : "" }
        }
        let natural = columns.map { values in
            let longest = values.map(displayLength).max() ?? 0
            return min(220, max(60, longest * 7.2 + 20))
        }
        let available = min(UIScreen.main.bounds.width - 32, 430)
        let total = natural.reduce(0, +)
        guard total > available, table.headers.count <= 3 else { return natural }

        let minimums = table.alignments.map { $0 == .trailing ? CGFloat(52) : CGFloat(82) }
        let minimumTotal = minimums.reduce(0, +)
        guard minimumTotal < available else { return minimums }
        let capacity = zip(natural, minimums).map { $0.0 - $0.1 }.reduce(0, +)
        guard capacity > 0 else { return natural }
        let ratio = min(1, (total - available) / capacity)
        return zip(natural, minimums).map { width, minimum in
            width - (width - minimum) * ratio
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                tableRow(table.headers, isHeader: true)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    tableRow(row, isHeader: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("markdown.table")
        .accessibilityLabel("Table")
    }

    private func tableRow(_ cells: [String], isHeader: Bool) -> some View {
        GridRow {
            ForEach(table.headers.indices, id: \.self) { index in
                SelectableAssistantText(
                    source: index < cells.count ? cells[index] : "",
                    style: isHeader ? .tableHeader : .body,
                    alignment: textAlignment(table.alignments[index]),
                    onAddToChat: onAddToChat
                )
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .frame(width: columnWidths[index], alignment: .topLeading)
                .background(isHeader ? VipiTheme.stroke.opacity(0.48) : Color.clear)
                .overlay {
                    Rectangle().stroke(VipiTheme.stroke, lineWidth: 0.5)
                }
            }
        }
    }

    private func textAlignment(_ alignment: MobileMarkdownTableAlignment) -> NSTextAlignment {
        switch alignment {
        case .leading: .natural
        case .center: .center
        case .trailing: .right
        }
    }

    private func displayLength(_ value: String) -> CGFloat {
        value.reduce(0) { length, character in
            length + (character.isASCII ? 1 : 1.75)
        }
    }
}

private struct SelectableAssistantText: UIViewRepresentable {
    enum Style: Equatable {
        case body
        case heading(Int)
        case quote
        case tableHeader

        var baseFont: UIFont {
            switch self {
            case .body, .quote:
                UIFont.preferredFont(forTextStyle: .body)
            case .tableHeader:
                UIFont.preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
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
    var alignment: NSTextAlignment = .natural
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
        let attributed = Self.makeAttributedText(source, style: style, alignment: alignment)
        if textView.attributedText != attributed { textView.attributedText = attributed }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    private static func makeAttributedText(
        _ source: String,
        style: Style,
        alignment: NSTextAlignment
    ) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return NSAttributedString(
                string: source,
                attributes: attributes(font: style.baseFont, color: style.color, alignment: alignment)
            )
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
            var runAttributes = attributes(font: font, color: style.color, alignment: alignment)
            if let link = run.link { runAttributes[.link] = link }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: runAttributes))
        }
        return result
    }

    private static func attributes(
        font: UIFont,
        color: UIColor,
        alignment: NSTextAlignment
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.alignment = alignment
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
                    .font(.caption.monospacedDigit().italic())
                    .foregroundStyle(VipiTheme.secondary)
                LiquidOrbView()
                    .frame(width: 28, height: 28)
                    .shadow(color: VipiTheme.accent.opacity(0.38), radius: 6)
                    .padding(.top, 7)
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

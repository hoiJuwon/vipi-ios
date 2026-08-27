import SwiftUI

struct SessionListView: View {
    @Environment(AppStore.self) private var store
    @State private var searchText = ""
    @State private var showsNewSession = CommandLine.arguments.contains("--session-picker-preview")
    let openSettings: () -> Void
    let openSession: (RemoteSession) -> Void

    init(
        openSettings: @escaping () -> Void = {},
        openSession: @escaping (RemoteSession) -> Void = { _ in }
    ) {
        self.openSettings = openSettings
        self.openSession = openSession
    }

    var body: some View {
        ZStack {
            VipiBackdrop()
            if filteredSessions.isEmpty && store.startingSessionPath == nil {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if let path = store.startingSessionPath,
                           searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            StartingSessionRow(path: path)
                            if !filteredSessions.isEmpty {
                                sessionDivider
                            }
                        }

                        ForEach(Array(filteredSessions.enumerated()), id: \.element.id) { index, session in
                            Button { openSession(session) } label: {
                                SessionRow(
                                    session: session,
                                    preview: preview(for: session)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("session.\(session.id)")
                            .accessibilityLabel(session.name)
                            .accessibilityValue(accessibilityValue(for: session))
                            .accessibilityHint("Opens the session transcript")

                            if index < filteredSessions.count - 1 {
                                sessionDivider
                            }
                        }
                    }
                }
                .refreshable { await store.connect() }
            }
        }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ProviderConnectionControl()
                    .frame(width: 44, height: 44)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("sessions.settings")
                .accessibilityLabel("Settings")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomControls
        }
        .sheet(isPresented: $showsNewSession) {
            NewSessionSheet()
                .environment(store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var sessionDivider: some View {
        Divider()
            .overlay(VipiTheme.stroke.opacity(0.66))
            .padding(.leading, 36)
            .padding(.trailing, 16)
    }

    private var bottomControls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(VipiTheme.secondary)

                TextField("Search", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("sessions.search")

                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(VipiTheme.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, minHeight: 54)
            .vipiGlass(interactive: true, in: Capsule())

            Button { showsNewSession = true } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(canCreateSession ? VipiTheme.primary : VipiTheme.secondary)
                    .frame(width: 54, height: 54)
                    .contentShape(Circle())
                    .vipiGlass(interactive: true, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canCreateSession)
            .accessibilityIdentifier("sessions.add")
            .accessibilityLabel("New session")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 7)
    }

    @ViewBuilder
    private var emptyState: some View {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                store.selectedProvider == .codex ? "No Codex sessions" : "No paired sessions",
                systemImage: store.selectedProvider == .codex ? "apple.terminal" : "lock.shield",
                description: Text(emptyDescription)
            )
            .accessibilityIdentifier("sessions.empty")
        } else {
            ContentUnavailableView.search(text: searchText)
        }
    }

    private var emptyDescription: String {
        if store.selectedProvider == .codex {
            return "Keep the Codex app-server daemon running on your paired Mac, then start a session here."
        }
        return "Open Settings to pair your Tailscale host, or explicitly choose demo data."
    }

    private var canCreateSession: Bool {
        switch store.connectionState(for: store.selectedProvider) {
        case .connected, .demo: true
        case .connecting, .disconnected: false
        }
    }

    private var filteredSessions: [RemoteSession] {
        let sorted = store.visibleSessions.sorted { $0.lastActivityAt > $1.lastActivityAt }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sorted }
        return sorted.filter { SessionListSearch.matches($0, query: query) }
    }

    private func preview(for session: RemoteSession) -> String {
        if let text = store.messages(for: session.id).last(where: {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.text {
            return text.replacingOccurrences(of: "\n", with: " ")
        }
        if let preview = session.lastMessagePreview,
           !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return preview
        }
        return "대화를 시작해보세요"
    }

    private func accessibilityValue(for session: RemoteSession) -> String {
        let unread = session.hasUnreadResponse ? ", 읽지 않은 응답 있음" : ""
        return "\(preview(for: session)), \(SessionListTimeFormatter.string(from: session.lastActivityAt))\(unread)"
    }
}

private struct StartingSessionRow: View {
    let path: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .tint(VipiTheme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Starting session…")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(VipiTheme.primary)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(VipiTheme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sessions.starting")
        .accessibilityLabel("Starting new session")
        .accessibilityValue(path)
    }
}

private struct NewSessionSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPath: String?

    var body: some View {
        NavigationStack {
            ZStack {
                VipiBackdrop()
                List {
                    if !store.registeredWorkspaces.isEmpty {
                        Section("Workspaces") {
                            ForEach(store.registeredWorkspaces, id: \.self) { path in
                                Button {
                                    selectedPath = path
                                    Task { await store.browseWorkspace(path) }
                                } label: {
                                    workspaceRow(path)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("workspace.registered.\(path)")
                            }
                        }
                    }

                    Section("Browse folders") {
                        if store.isLoadingWorkspaces && store.workspaceDirectory == nil {
                            loadingRow("Loading workspaces…")
                        } else if let directory = store.workspaceDirectory {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(directoryName(directory.path))
                                    .font(.headline)
                                    .foregroundStyle(VipiTheme.primary)
                                Text(abbreviatedPath(directory.path))
                                    .font(.caption)
                                    .foregroundStyle(VipiTheme.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(.vertical, 4)
                            .accessibilityIdentifier("workspace.current")

                            if let parent = directory.parent {
                                Button {
                                    selectedPath = parent
                                    Task { await store.browseWorkspace(parent) }
                                } label: {
                                    Label("Up one level", systemImage: "arrow.up.left")
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("workspace.parent")
                            }

                            ForEach(directory.directories, id: \.self) { path in
                                Button {
                                    selectedPath = path
                                    Task { await store.browseWorkspace(path) }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "folder")
                                            .foregroundStyle(VipiTheme.secondary)
                                        Text(directoryName(path))
                                            .foregroundStyle(VipiTheme.primary)
                                            .lineLimit(1)
                                        Spacer(minLength: 8)
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(VipiTheme.secondary)
                                    }
                                    .frame(minHeight: 44)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("workspace.folder.\(path)")
                            }

                            if directory.directories.isEmpty && !store.isBrowsingWorkspace {
                                Text("No subfolders")
                                    .font(.subheadline)
                                    .foregroundStyle(VipiTheme.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .center)
                            }
                        }
                    }

                    if let error = store.sessionCreationError {
                        Section {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.subheadline)
                                .foregroundStyle(VipiTheme.danger)
                                .accessibilityIdentifier("session.creation.error")
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .disabled(store.isCreatingSession)

                if store.isBrowsingWorkspace {
                    ProgressView()
                        .controlSize(.large)
                        .padding(18)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityLabel("Loading folder")
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .disabled(store.isCreatingSession)
                    .accessibilityLabel("Close")
                }
            }
            .safeAreaInset(edge: .bottom) {
                startButton
            }
        }
        .interactiveDismissDisabled(store.isCreatingSession)
        .task { await store.prepareSessionCreation() }
        .onChange(of: store.workspaceDirectory?.path) { _, path in
            if let path { selectedPath = path }
        }
        .onChange(of: store.sessionCreationSucceeded) { _, succeeded in
            if succeeded { dismiss() }
        }
    }

    private var startButton: some View {
        VStack(spacing: 0) {
            Divider().overlay(VipiTheme.stroke)
            Button {
                guard let selectedPath else { return }
                Task { await store.createSession(in: selectedPath) }
            } label: {
                HStack(spacing: 8) {
                    if store.isCreatingSession {
                        ProgressView().tint(VipiTheme.primaryActionForeground)
                        Text("Starting…")
                    } else {
                        Image(systemName: "plus")
                        Text("Start in \(directoryName(selectedPath ?? ""))")
                    }
                }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .tint(VipiTheme.primaryAction)
            .foregroundStyle(VipiTheme.primaryActionForeground)
            .disabled(selectedPath == nil || store.isCreatingSession || store.isLoadingWorkspaces)
            .accessibilityIdentifier("session.create")
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private func workspaceRow(_ path: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(VipiTheme.primary)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(directoryName(path))
                    .font(.body.weight(.medium))
                    .foregroundStyle(VipiTheme.primary)
                    .lineLimit(1)
                Text(abbreviatedPath(URL(fileURLWithPath: path).deletingLastPathComponent().path))
                    .font(.caption)
                    .foregroundStyle(VipiTheme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Image(systemName: selectedPath == path ? "checkmark.circle.fill" : "chevron.right")
                .foregroundStyle(selectedPath == path ? VipiTheme.primary : VipiTheme.secondary)
        }
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(VipiTheme.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
    }

    private func directoryName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func abbreviatedPath(_ path: String) -> String {
        guard let home = store.workspaceHome, path.hasPrefix(home) else { return path }
        let suffix = String(path.dropFirst(home.count))
        return suffix.isEmpty ? "~" : "~\(suffix)"
    }
}

private struct SessionRow: View {
    let session: RemoteSession
    let preview: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Group {
                        if session.phase == .working {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(VipiTheme.accent)
                        } else {
                            Circle()
                                .fill(session.hasUnreadResponse ? Color.green : Color.clear)
                                .frame(width: 8, height: 8)
                        }
                    }
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)

                    Text(session.name)
                        .font(.body.weight(session.hasUnreadResponse ? .bold : .semibold))
                        .foregroundStyle(VipiTheme.primary)
                        .lineLimit(1)
                }

                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(VipiTheme.secondary)
                    .lineLimit(2)
                    .padding(.leading, 20)
            }

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                Text(SessionListTimeFormatter.string(from: session.lastActivityAt))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(VipiTheme.secondary)
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VipiTheme.secondary.opacity(0.65))
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private extension RemoteSession {
    var hasUnreadResponse: Bool { unread || phase == .waitingForInput }
}

enum SessionListSearch {
    static func matches(_ session: RemoteSession, query: String) -> Bool {
        session.name.localizedCaseInsensitiveContains(query)
    }
}

enum SessionListTimeFormatter {
    private static let timeZone = TimeZone(identifier: "Asia/Seoul")!

    static func string(from date: Date, now: Date = .now) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")

        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "h:mm a"
        } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            formatter.dateFormat = "MMM d"
        } else {
            formatter.dateFormat = "yyyy.MM.dd"
        }
        return formatter.string(from: date)
    }
}

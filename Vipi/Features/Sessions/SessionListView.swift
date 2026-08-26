import SwiftUI

struct SessionListView: View {
    @Environment(AppStore.self) private var store
    @State private var searchText = ""

    var body: some View {
        ZStack {
            VipiBackdrop()
            if filteredSessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredSessions.enumerated()), id: \.element.id) { index, session in
                            NavigationLink(value: session) {
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
                                Divider()
                                    .overlay(VipiTheme.stroke.opacity(0.7))
                                    .padding(.horizontal, 16)
                            }
                        }
                    }
                }
                .refreshable { await store.connect() }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search sessions")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ConnectionCapsule(state: store.connectionState)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .vipiGlass(in: Capsule())
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "No paired sessions",
                systemImage: "lock.shield",
                description: Text("Open Settings to pair your Tailscale host, or explicitly choose demo data.")
            )
            .accessibilityIdentifier("sessions.empty")
        } else {
            ContentUnavailableView.search(text: searchText)
        }
    }

    private var filteredSessions: [RemoteSession] {
        let sorted = store.sessions.sorted { $0.lastActivityAt > $1.lastActivityAt }
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

private struct SessionRow: View {
    let session: RemoteSession
    let preview: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text(session.name)
                        .font(.body.weight(session.hasUnreadResponse ? .bold : .semibold))
                        .foregroundStyle(VipiTheme.primary)
                        .lineLimit(1)
                    if session.phase == .working {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(VipiTheme.accent)
                            .accessibilityHidden(true)
                    }
                }

                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(VipiTheme.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                Text(SessionListTimeFormatter.string(from: session.lastActivityAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(VipiTheme.secondary)
                    .lineLimit(1)

                if session.hasUnreadResponse {
                    Text("1")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(VipiTheme.danger, in: Capsule())
                        .accessibilityLabel("읽지 않은 응답 1개")
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .contentShape(Rectangle())
        .background(session.hasUnreadResponse ? VipiTheme.accent.opacity(0.055) : Color.clear)
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

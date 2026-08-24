import SwiftUI

struct SessionListView: View {
    @Environment(AppStore.self) private var store
    @State private var searchText = ""

    var body: some View {
        ZStack {
            VipiBackdrop()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    hero
                    ForEach(filteredGroups) { group in
                        workspaceSection(group)
                    }
                    Color.clear.frame(height: 16)
                }
                .padding(.horizontal, 16)
            }
            .refreshable { await store.connect() }
        }
        .navigationTitle("Vipi")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search sessions")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 8) {
                    Image(systemName: "circle.hexagongrid.fill").foregroundStyle(VipiTheme.accent)
                    ConnectionCapsule(state: store.connectionState)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .vipiGlass(in: Capsule())
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your Pi sessions")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Pick up any tmux session without leaving the conversation.")
                .font(.subheadline)
                .foregroundStyle(VipiTheme.secondary)
            HStack(spacing: 16) {
                metric("\(store.sessions.filter { $0.phase == .working }.count)", "running")
                metric("\(store.sessions.filter(\.unread).count)", "unread")
                metric("\(store.workspaceGroups.count)", "workspaces")
            }
            .padding(.top, 4)
        }
        .padding(.top, 14)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value).font(.title3.bold()).foregroundStyle(VipiTheme.primary)
            Text(label).font(.caption).foregroundStyle(VipiTheme.secondary)
        }
    }

    private func workspaceSection(_ group: WorkspaceGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "folder.fill").foregroundStyle(VipiTheme.secondary)
                Text(URL(fileURLWithPath: group.path).lastPathComponent)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(group.sessions.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(VipiTheme.secondary)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                    NavigationLink(value: session) { SessionRow(session: session) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("session.\(session.id)")
                    if index < group.sessions.count - 1 {
                        Divider().overlay(VipiTheme.stroke).padding(.leading, 58)
                    }
                }
            }
            .vipiCard()
        }
    }

    private var filteredGroups: [WorkspaceGroup] {
        guard !searchText.isEmpty else { return store.workspaceGroups }
        return store.workspaceGroups.compactMap { group in
            let sessions = group.sessions.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.cwd.localizedCaseInsensitiveContains(searchText)
            }
            return sessions.isEmpty ? nil : WorkspaceGroup(path: group.path, sessions: sessions)
        }
    }
}

private struct SessionRow: View {
    let session: RemoteSession

    var body: some View {
        HStack(spacing: 13) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(session.phase.color.opacity(0.12))
                    .frame(width: 43, height: 43)
                    .overlay { Image(systemName: "terminal.fill").foregroundStyle(session.phase.color) }
                if session.unread {
                    Circle().fill(VipiTheme.success).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(VipiTheme.surface, lineWidth: 2))
                        .offset(x: 2, y: -2)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(session.name).font(.body.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(session.lastActivityAt, style: .relative)
                        .font(.caption2).foregroundStyle(VipiTheme.secondary)
                }
                HStack(spacing: 7) {
                    Circle().fill(session.phase.color).frame(width: 6, height: 6)
                    Text(session.phase.label)
                    Text("·")
                    Text(session.model)
                    if let branch = session.branch {
                        Text("·"); Image(systemName: "arrow.triangle.branch"); Text(branch)
                    }
                }
                .font(.caption)
                .foregroundStyle(VipiTheme.secondary)
                .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.caption.bold()).foregroundStyle(VipiTheme.secondary.opacity(0.5))
        }
        .padding(14)
        .contentShape(Rectangle())
    }
}

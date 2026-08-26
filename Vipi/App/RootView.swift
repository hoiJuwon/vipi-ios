import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if CommandLine.arguments.contains("--chat-preview") {
                NavigationStack { ChatView(sessionID: "mobile") }
            } else {
                tabs
            }
        }
        .overlay(alignment: .bottom) {
            if let interaction = store.pendingInteractions.first(where: { $0.sessionID != store.selectedSessionID }) {
                RemoteInteractionCard(
                    interaction: interaction,
                    sessionName: store.session(id: interaction.sessionID)?.name
                ) { response in
                    Task { await store.respond(to: interaction, with: response) }
                }
                .id(interaction.requestID)
                .padding(.horizontal, 12)
                .padding(.bottom, 62)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: store.pendingInteractions.first?.requestID)
    }

    private var tabs: some View {
        TabView {
            NavigationStack {
                SessionListView()
                    .navigationDestination(for: RemoteSession.self) { session in
                        ChatView(sessionID: session.id)
                    }
            }
            .tabItem { Label("Sessions", systemImage: "bubble.left.and.bubble.right.fill") }

            NavigationStack { ActivityView() }
                .tabItem { Label("Activity", systemImage: "waveform.path.ecg") }

            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
        }
        .tint(VipiTheme.accent)
    }
}

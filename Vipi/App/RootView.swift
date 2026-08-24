import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if CommandLine.arguments.contains("--chat-preview") {
            NavigationStack { ChatView(sessionID: "mobile") }
        } else {
            tabs
        }
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

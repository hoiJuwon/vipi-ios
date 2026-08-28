import SwiftUI

struct VipiSplashView: View {
    @State private var typedName = ""
    @State private var cursorVisible = true

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color(red: 3 / 255, green: 7 / 255, blue: 18 / 255)

                Image("SplashBackground")
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()

                HStack(alignment: .center, spacing: 4) {
                    Text(typedName)
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.94))

                    Rectangle()
                        .fill(Color(red: 0.55, green: 0.76, blue: 1))
                        .frame(width: 11, height: 24)
                        .opacity(cursorVisible ? 1 : 0.16)
                }
                .frame(width: 74, alignment: .leading)
                .offset(y: geometry.size.height * 0.655)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("splash.view")
        .accessibilityLabel("vipi")
        .task {
            typedName = ""
            cursorVisible = true
            try? await Task.sleep(for: .milliseconds(180))
            for character in "vipi" {
                guard !Task.isCancelled else { return }
                typedName.append(character)
                try? await Task.sleep(for: .milliseconds(90))
            }
            try? await Task.sleep(for: .milliseconds(90))
            withAnimation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true)) {
                cursorVisible = false
            }
        }
    }
}

struct RootView: View {
    private enum Route: Hashable {
        case session(String)
        case settings
    }

    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [Route] = []

    var body: some View {
        Group {
            if CommandLine.arguments.contains("--chat-preview") {
                NavigationStack { ChatView(sessionID: "mobile") }
            } else {
                navigation
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
        .onAppear { openNotificationSessionIfAvailable() }
        .onChange(of: store.notificationRouteRequest) { _, _ in openNotificationSessionIfAvailable() }
        .onChange(of: store.sessions.map(\.id)) { _, _ in openNotificationSessionIfAvailable() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { openNotificationSessionIfAvailable() }
        }
    }

    private var navigation: some View {
        NavigationStack(path: $path) {
            SessionListView(
                openSettings: { path.append(.settings) },
                openSession: { path.append(.session($0.id)) }
            )
            .navigationDestination(for: Route.self) { route in
                switch route {
                case let .session(sessionID): ChatView(sessionID: sessionID)
                case .settings: SettingsView()
                }
            }
        }
        .tint(VipiTheme.accent)
    }

    private func openNotificationSessionIfAvailable() {
        guard let sessionID = store.requestedNotificationSessionID,
              store.session(id: sessionID) != nil else { return }
        if let session = store.session(id: sessionID), session.agentProvider != store.selectedProvider {
            store.selectProvider(session.agentProvider)
        }
        path = [.session(sessionID)]
        store.consumeNotificationSessionRequest()
        PushNotificationCoordinator.clearPendingSessionID(sessionID)
    }
}

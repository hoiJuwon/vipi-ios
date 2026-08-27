import SwiftUI

struct VipiSplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    Text("vipi")
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.94))

                    Rectangle()
                        .fill(Color(red: 0.55, green: 0.76, blue: 1))
                        .frame(width: 11, height: 24)
                        .opacity(reduceMotion || cursorVisible ? 1 : 0.16)
                }
                .offset(y: geometry.size.height * 0.655)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("splash.view")
        .accessibilityLabel("vipi")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.48).repeatForever(autoreverses: true)) {
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
        .onChange(of: store.requestedNotificationSessionID) { _, _ in openNotificationSessionIfAvailable() }
        .onChange(of: store.sessions.map(\.id)) { _, _ in openNotificationSessionIfAvailable() }
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
        path = [.session(sessionID)]
        store.consumeNotificationSessionRequest()
    }
}

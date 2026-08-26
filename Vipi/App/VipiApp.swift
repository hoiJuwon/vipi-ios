import SwiftUI

@main
struct VipiApp: App {
    @State private var store: AppStore
    @State private var showsSplash: Bool
    private let holdsSplashForPreview: Bool

    init() {
        #if DEBUG
        let allowsLocalhost = CommandLine.arguments.contains("--uitesting")
        #else
        let allowsLocalhost = false
        #endif
        let broker = BrokerClient(allowsInsecureLocalhostForUITesting: allowsLocalhost)
        let hasLiveFixture = ProcessInfo.processInfo.environment["VIPI_E2E_PAIRING"] != nil
        let splashPreview = CommandLine.arguments.contains("--splash-preview")
        holdsSplashForPreview = splashPreview
        _showsSplash = State(initialValue: splashPreview || !allowsLocalhost)
        _store = State(initialValue: AppStore(
            broker: broker,
            allowsInsecureLocalhostForUITesting: allowsLocalhost,
            startsInDemoMode: allowsLocalhost && !hasLiveFixture
        ))
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .accessibilityHidden(showsSplash)

                if showsSplash {
                    VipiSplashView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .environment(store)
            .statusBarHidden(showsSplash)
            .persistentSystemOverlays(showsSplash ? .hidden : .automatic)
            .task { await store.connectIfConfigured() }
            .task {
                guard showsSplash, !holdsSplashForPreview else { return }
                try? await Task.sleep(for: .milliseconds(1_650))
                withAnimation(.easeOut(duration: 0.32)) { showsSplash = false }
            }
        }
    }
}

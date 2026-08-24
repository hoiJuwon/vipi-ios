import SwiftUI

@main
struct VipiApp: App {
    @State private var store: AppStore

    init() {
        #if DEBUG
        let allowsLocalhost = CommandLine.arguments.contains("--uitesting")
        #else
        let allowsLocalhost = false
        #endif
        let broker = BrokerClient(allowsInsecureLocalhostForUITesting: allowsLocalhost)
        let hasLiveFixture = ProcessInfo.processInfo.environment["VIPI_E2E_PAIRING"] != nil
        _store = State(initialValue: AppStore(
            broker: broker,
            allowsInsecureLocalhostForUITesting: allowsLocalhost,
            startsInDemoMode: allowsLocalhost && !hasLiveFixture
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .task { await store.connectIfConfigured() }
        }
    }
}

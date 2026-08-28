import SwiftUI
import UIKit
import UserNotifications

extension Notification.Name {
    static let vipiPushTokenUpdated = Notification.Name("vipi.push-token-updated")
    static let vipiOpenSession = Notification.Name("vipi.open-session")
}

enum PushAuthorizationState: String {
    case unknown, notDetermined, denied, enabled

    var label: String {
        switch self {
        case .unknown: "Checking…"
        case .notDetermined: "Off"
        case .denied: "Disabled in Settings"
        case .enabled: "Enabled"
        }
    }
}

struct PushDeviceRegistration: Codable, Equatable {
    let deviceToken: String
    let environment: String
}

@MainActor
enum PushNotificationCoordinator {
    private static let registrationKey = "vipi.apnsRegistration"
    private static let pendingSessionKey = "vipi.pendingPushSession"

    static var registration: PushDeviceRegistration? {
        guard let data = UserDefaults.standard.data(forKey: registrationKey) else { return nil }
        return try? JSONDecoder().decode(PushDeviceRegistration.self, from: data)
    }

    static func prepare() async -> PushAuthorizationState {
        let status = await authorizationState()
        if status == .enabled {
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        }
        return status
    }

    static func requestAuthorization() async -> PushAuthorizationState {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            if granted {
                await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
            }
        } catch {}
        return await authorizationState()
    }

    static func authorizationState() async -> PushAuthorizationState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .enabled
        @unknown default: return .unknown
        }
    }

    static func store(deviceToken data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        let value = PushDeviceRegistration(deviceToken: token, environment: environment)
        if let encoded = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(encoded, forKey: registrationKey)
        }
        NotificationCenter.default.post(name: .vipiPushTokenUpdated, object: nil)
    }

    static func open(sessionID: String) {
        UserDefaults.standard.set(sessionID, forKey: pendingSessionKey)
        NotificationCenter.default.post(name: .vipiOpenSession, object: sessionID)
    }

    static func pendingSessionID() -> String? {
        UserDefaults.standard.string(forKey: pendingSessionKey)
    }

    static func clearPendingSessionID(_ sessionID: String) {
        guard UserDefaults.standard.string(forKey: pendingSessionKey) == sessionID else { return }
        UserDefaults.standard.removeObject(forKey: pendingSessionKey)
    }
}

final class VipiAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushNotificationCoordinator.store(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // The Settings screen reports authorization and host configuration;
        // device-specific APNs errors remain non-fatal.
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        if let sessionID = response.notification.request.content.userInfo["sessionID"] as? String {
            await PushNotificationCoordinator.open(sessionID: sessionID)
        }
    }
}

@main
struct VipiApp: App {
    @UIApplicationDelegateAdaptor(VipiAppDelegate.self) private var appDelegate
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
                #if DEBUG
                if let flag = CommandLine.arguments.firstIndex(of: "--notification-session"),
                   CommandLine.arguments.indices.contains(flag + 1) {
                    store.requestSessionFromNotification(CommandLine.arguments[flag + 1])
                }
                #endif
            }
            .task {
                guard !CommandLine.arguments.contains("--uitesting") else { return }
                if CommandLine.arguments.contains("--request-notifications") {
                    _ = await PushNotificationCoordinator.requestAuthorization()
                } else {
                    _ = await PushNotificationCoordinator.prepare()
                }
                await store.registerPushDeviceIfAvailable()
                if let sessionID = PushNotificationCoordinator.pendingSessionID() {
                    store.requestSessionFromNotification(sessionID)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .vipiPushTokenUpdated)) { _ in
                Task { await store.registerPushDeviceIfAvailable() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .vipiOpenSession)) { notification in
                if let sessionID = notification.object as? String {
                    store.requestSessionFromNotification(sessionID)
                }
            }
            .task {
                guard showsSplash, !holdsSplashForPreview else { return }
                try? await Task.sleep(for: .milliseconds(1_650))
                withAnimation(.easeOut(duration: 0.32)) { showsSplash = false }
            }
        }
    }
}

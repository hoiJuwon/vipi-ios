import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var pairingPayload = ""
    @State private var pairingError: String?
    @State private var pushAuthorization: PushAuthorizationState = .unknown

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "network").font(.title2).foregroundStyle(VipiTheme.accent)
                    VStack(alignment: .leading) {
                        Text("Mac Studio").font(.headline)
                        Text(store.host).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(); ConnectionCapsule(state: store.connectionState)
                }
            }
            Section("Pair device") {
                SecureField("Paste pairing payload", text: $pairingPayload)
                    .accessibilityIdentifier("settings.pairingPayload")
                    .textInputAutocapitalization(.never)
                    .privacySensitive()
                Button("Import pairing payload", systemImage: "qrcode") {
                    do {
                        try store.pair(payload: pairingPayload)
                        pairingPayload = ""
                        pairingError = nil
                    } catch {
                        pairingError = error.localizedDescription
                    }
                }
                .disabled(pairingPayload.isEmpty)
                .accessibilityIdentifier("settings.importPairing")
                if let pairingError {
                    Text(pairingError).font(.caption).foregroundStyle(VipiTheme.danger)
                }
            }
            Section("Tailnet host") {
                TextField("https://host.tailnet.ts.net", text: $store.host)
                    .accessibilityIdentifier("settings.host")
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                SecureField("Device token", text: $store.token)
                    .accessibilityIdentifier("settings.token")
                    .privacySensitive()
                Button {
                    Task { await store.connect() }
                } label: {
                    HStack { Spacer(); if store.connectionState == .connecting { ProgressView().padding(.trailing, 6) }; Text("Connect securely"); Spacer() }
                }
                .accessibilityIdentifier("settings.connect")
                Button("Rotate device token", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await store.rotateToken() }
                }
                .disabled(store.connectionState != .connected)
                .accessibilityIdentifier("settings.rotateToken")
                Button("Use demo data") { store.useDemoMode() }.foregroundStyle(VipiTheme.warning)
            }
            Section("Notifications") {
                LabeledContent("Answer alerts", value: pushAuthorization.label)
                if pushAuthorization == .notDetermined {
                    Button("Enable notifications", systemImage: "bell") {
                        Task {
                            pushAuthorization = await PushNotificationCoordinator.requestAuthorization()
                            await store.registerPushDeviceIfAvailable()
                            await store.refreshPushStatus()
                        }
                    }
                    .accessibilityIdentifier("settings.enableNotifications")
                } else if pushAuthorization == .denied {
                    Button("Open iOS Settings", systemImage: "gear") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                if pushAuthorization == .enabled {
                    LabeledContent(
                        "Vipi host",
                        value: store.pushHostConfigured ? "Ready" : "APNs key required"
                    )
                    LabeledContent("Registered devices", value: "\(store.pushRegisteredDevices)")
                }
                if let error = store.pushRegistrationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(VipiTheme.danger)
                }
                Text("Alerts contain the session name and a generic completion message, not the answer text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("App", value: "Vipi 0.1.0")
                LabeledContent("Protocol", value: "v1")
                Text("A paired device can ask Pi to execute commands and modify files. Keep the host private to your tailnet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background { VipiBackdrop() }
        .navigationTitle("Settings")
        .task {
            pushAuthorization = await PushNotificationCoordinator.authorizationState()
            await store.refreshPushStatus()
        }
    }
}

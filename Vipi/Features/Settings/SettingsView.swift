import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store

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
            Section("Tailnet host") {
                TextField("https://host.tailnet.ts.net", text: $store.host)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                SecureField("Device token", text: $store.token)
                Button {
                    Task { await store.connect() }
                } label: {
                    HStack { Spacer(); if store.connectionState == .connecting { ProgressView().padding(.trailing, 6) }; Text("Connect securely"); Spacer() }
                }
                Button("Use demo data") { store.useDemoMode() }.foregroundStyle(VipiTheme.warning)
            }
            Section("Connection") {
                Toggle("Reconnect automatically", isOn: .constant(true))
                Toggle("Notify when a run finishes", isOn: .constant(true))
                Toggle("Notify when Pi needs input", isOn: .constant(true))
            }
            Section("About") {
                LabeledContent("App", value: "Vipi 0.1.0")
                LabeledContent("Protocol", value: "v1")
                Text("A paired device can ask Pi to execute commands and modify files. Keep the host private to your tailnet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(VipiTheme.canvas)
        .navigationTitle("Settings")
    }
}

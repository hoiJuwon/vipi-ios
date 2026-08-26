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
        .sheet(item: pendingInteraction) { interaction in
            RemoteInteractionSheet(
                interaction: interaction,
                sessionName: store.session(id: interaction.sessionID)?.name
            ) { response in
                Task { await store.respond(to: interaction, with: response) }
            }
            .interactiveDismissDisabled()
        }
    }

    private var pendingInteraction: Binding<RemoteInteraction?> {
        Binding(
            get: { store.pendingInteractions.first },
            set: { _ in }
        )
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

private struct RemoteInteractionSheet: View {
    let interaction: RemoteInteraction
    let sessionName: String?
    let respond: (JSONValue) -> Void
    @State private var input = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    if let sessionName {
                        Text(sessionName.components(separatedBy: " / ").last ?? sessionName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(VipiTheme.accent)
                    }
                    Text(interaction.title)
                        .font(.title3.weight(.semibold))
                    if let message = interaction.message, !message.isEmpty {
                        Text(message)
                            .font(.body)
                            .foregroundStyle(VipiTheme.secondary)
                            .textSelection(.enabled)
                    }
                }

                interactionControls
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Action required")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("interaction.sheet")
    }

    @ViewBuilder
    private var interactionControls: some View {
        switch interaction.kind {
        case .confirm:
            HStack(spacing: 12) {
                Button("Deny", role: .destructive) { respond(.bool(false)) }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button("Allow") { respond(.bool(true)) }
                    .buttonStyle(.borderedProminent)
                    .tint(VipiTheme.accent)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        case .select:
            VStack(spacing: 10) {
                ForEach(interaction.options ?? [], id: \.self) { option in
                    Button(option) { respond(.string(option)) }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Cancel", role: .cancel) { respond(.null) }
                    .buttonStyle(.plain)
                    .foregroundStyle(VipiTheme.secondary)
            }
        case .input:
            VStack(spacing: 12) {
                TextField(interaction.placeholder ?? "Response", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .vipiGlass(interactive: true, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityIdentifier("interaction.input")
                HStack(spacing: 12) {
                    Button("Cancel", role: .cancel) { respond(.null) }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    Button("Submit") { respond(.string(input)) }
                        .buttonStyle(.borderedProminent)
                        .tint(VipiTheme.accent)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
        }
    }
}

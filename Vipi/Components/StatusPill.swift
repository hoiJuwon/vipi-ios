import SwiftUI

struct StatusPill: View {
    let phase: SessionPhase

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(phase.color).frame(width: 7, height: 7)
            Text(phase.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(phase.color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .vipiGlass(tint: phase.color.opacity(0.18), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Session status")
        .accessibilityValue(phase.label)
    }
}

struct ProviderConnectionControl: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Menu {
            ForEach(AgentProvider.allCases, id: \.self) { provider in
                Button {
                    store.selectProvider(provider)
                } label: {
                    Label {
                        Text(provider.displayName)
                    } icon: {
                        Image(systemName: provider == store.selectedProvider ? "checkmark.circle.fill" : provider.symbolName)
                    }
                }
                .accessibilityIdentifier("provider.\(provider.rawValue)")
            }
        } label: {
            ProviderMark(
                provider: store.selectedProvider,
                state: store.connectionState(for: store.selectedProvider)
            )
            .frame(width: 32, height: 32)
        }
        .accessibilityIdentifier("connection.status")
        .accessibilityLabel("Connection")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Selects Vipi or Codex sessions")
    }

    private var accessibilityValue: String {
        let state = store.connectionState(for: store.selectedProvider)
        let status: String
        switch state {
        case .demo: status = "Demo"
        case .connecting: status = "Connecting"
        case .connected: status = "Connected"
        case .disconnected: status = "Offline"
        }
        return "\(store.selectedProvider.displayName), \(status)"
    }
}

private struct ProviderMark: View {
    let provider: AgentProvider
    let state: AppStore.ConnectionState

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            providerIcon
                .frame(width: 27, height: 27)

            switch state {
            case .connecting:
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
                    .background(.ultraThinMaterial, in: Circle())
            case .connected:
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .overlay { Circle().stroke(VipiTheme.canvas, lineWidth: 1.5) }
            case .demo:
                Circle()
                    .fill(VipiTheme.warning)
                    .frame(width: 8, height: 8)
                    .overlay { Circle().stroke(VipiTheme.canvas, lineWidth: 1.5) }
            case .disconnected:
                Circle()
                    .fill(VipiTheme.secondary)
                    .frame(width: 8, height: 8)
                    .overlay { Circle().stroke(VipiTheme.canvas, lineWidth: 1.5) }
            }
        }
    }

    @ViewBuilder
    private var providerIcon: some View {
        switch provider {
        case .pi:
            Image("BrandIcon")
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        case .codex:
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.48, green: 0.54, blue: 1), Color(red: 0.25, green: 0.2, blue: 0.95)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "apple.terminal.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }
}

private extension AgentProvider {
    var symbolName: String {
        switch self {
        case .pi: "bubble.left.and.text.bubble.right.fill"
        case .codex: "apple.terminal.fill"
        }
    }
}

struct ConnectionCapsule: View {
    let state: AppStore.ConnectionState

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.caption.weight(.medium))
                .fixedSize()
        }
        .foregroundStyle(color)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("connection.status")
        .accessibilityLabel("Connection")
        .accessibilityValue(label)
    }

    private var label: String {
        switch state {
        case .demo: "Demo"
        case .connecting: "Connecting"
        case .connected: "Live"
        case .disconnected: "Offline"
        }
    }

    private var color: Color {
        switch state {
        case .demo: VipiTheme.warning
        case .connecting: VipiTheme.cyan
        case .connected: VipiTheme.success
        case .disconnected: VipiTheme.secondary
        }
    }
}

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
        .background(phase.color.opacity(0.12), in: Capsule())
    }
}

struct ConnectionCapsule: View {
    let state: AppStore.ConnectionState

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption.weight(.medium))
        }
        .foregroundStyle(color)
    }

    private var label: String {
        switch state {
        case .demo: "Demo"
        case .connecting: "Connecting"
        case .connected: "Tailnet"
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

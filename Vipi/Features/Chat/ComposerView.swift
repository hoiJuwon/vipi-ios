import SwiftUI

struct ComposerView: View {
    @Binding var draft: String
    let phase: SessionPhase
    let onSend: (PromptDelivery) -> Void
    @State private var selectedDelivery: PromptDelivery = .followUp

    var body: some View {
        HStack(alignment: .bottom, spacing: 9) {
            TextField(phase == .offline ? "Reconnecting session…" : "Message Pi…", text: $draft, axis: .vertical)
                .accessibilityIdentifier("chat.composer")
                .accessibilityLabel("Message Pi")
                .lineLimit(1...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .vipiGlass(interactive: phase != .offline, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .disabled(phase == .offline)

            if phase == .working {
                Menu {
                    Picker("Delivery", selection: $selectedDelivery) {
                        Text("Queue after response").tag(PromptDelivery.followUp)
                        Text("Steer current response").tag(PromptDelivery.steer)
                    }
                } label: {
                    Image(systemName: selectedDelivery == .steer ? "arrow.triangle.turn.up.right.diamond.fill" : "text.line.last.and.arrowtriangle.forward")
                        .font(.subheadline.bold())
                        .foregroundStyle(VipiTheme.accent)
                        .frame(width: 38, height: 38)
                        .vipiGlass(interactive: true, in: Circle())
                }
                .accessibilityLabel("Message delivery mode")
            }

            Button { onSend(phase == .working ? selectedDelivery : .prompt) } label: {
                Image(systemName: "arrow.up")
                    .font(.body.bold())
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .vipiGlass(
                        tint: draft.isEmpty ? VipiTheme.secondary.opacity(0.2) : VipiTheme.accent,
                        interactive: true,
                        in: Circle()
                    )
            }
            .disabled(phase == .offline || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("chat.send")
            .accessibilityLabel("Send message")
            .accessibilityHint(phase == .working ? "Delivers using the selected queue or steer mode" : "Sends a prompt to Pi")
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 7)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().overlay(VipiTheme.stroke) }
    }
}

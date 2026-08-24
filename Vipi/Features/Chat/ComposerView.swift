import SwiftUI

struct ComposerView: View {
    @Binding var draft: String
    let phase: SessionPhase
    let onSend: (PromptDelivery) -> Void
    @State private var selectedDelivery: PromptDelivery = .prompt

    var body: some View {
        VStack(spacing: 8) {
            if phase == .working {
                HStack(spacing: 8) {
                    Text("Pi is working").font(.caption.weight(.medium)).foregroundStyle(VipiTheme.secondary)
                    Spacer()
                    Picker("Delivery", selection: $selectedDelivery) {
                        Text("Queue").tag(PromptDelivery.followUp)
                        Text("Steer").tag(PromptDelivery.steer)
                    }
                    .pickerStyle(.segmented).frame(width: 150)
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message Pi…", text: $draft, axis: .vertical)
                    .accessibilityIdentifier("chat.composer")
                    .accessibilityLabel("Message Pi")
                    .lineLimit(1...6)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .vipiGlass(interactive: true, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Button { onSend(phase == .working ? selectedDelivery : .prompt) } label: {
                    Image(systemName: phase == .working && draft.isEmpty ? "stop.fill" : "arrow.up")
                        .font(.body.bold()).foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .vipiGlass(
                            tint: draft.isEmpty ? VipiTheme.secondary.opacity(0.2) : VipiTheme.accent,
                            interactive: true,
                            in: Circle()
                        )
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("chat.send")
                .accessibilityLabel("Send message")
                .accessibilityHint(phase == .working ? "Delivers using the selected queue or steer mode" : "Sends a prompt to Pi")
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
    }
}

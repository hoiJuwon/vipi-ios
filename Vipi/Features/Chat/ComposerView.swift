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
                Button { } label: {
                    Image(systemName: "plus").frame(width: 34, height: 34)
                        .background(VipiTheme.elevated, in: Circle())
                }
                .foregroundStyle(VipiTheme.primary)
                TextField("Message Pi…", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(VipiTheme.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Button { onSend(phase == .working ? selectedDelivery : .prompt) } label: {
                    Image(systemName: phase == .working && draft.isEmpty ? "stop.fill" : "arrow.up")
                        .font(.body.bold()).foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(draft.isEmpty ? VipiTheme.secondary.opacity(0.4) : VipiTheme.accent, in: Circle())
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().overlay(VipiTheme.stroke) }
    }
}

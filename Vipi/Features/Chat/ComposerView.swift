import SwiftUI

struct ComposerView: View {
    @Binding var draft: String
    let phase: SessionPhase
    let queuedPrompts: [QueuedPrompt]
    let onSend: (PromptDelivery) -> Void
    let onStop: () -> Void

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isWorking: Bool { phase == .working }
    private var showsStop: Bool { isWorking && trimmedDraft.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let first = queuedPrompts.first {
                HStack(spacing: 6) {
                    Text("Queued")
                        .foregroundStyle(VipiTheme.accent)
                    Text(first.text)
                        .foregroundStyle(VipiTheme.secondary)
                        .lineLimit(1)
                    if queuedPrompts.count > 1 {
                        Text("+\(queuedPrompts.count - 1)")
                            .foregroundStyle(VipiTheme.secondary)
                    }
                }
                .font(.caption)
                .padding(.horizontal, 14)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chat.queue")
                .accessibilityLabel("Queued messages")
                .accessibilityValue("\(queuedPrompts.count)")
            }

            HStack(alignment: .bottom, spacing: 9) {
                TextField(phase == .offline ? "Reconnecting session…" : "Message Pi…", text: $draft, axis: .vertical)
                    .accessibilityIdentifier("chat.composer")
                    .accessibilityLabel("Message Pi")
                    .lineLimit(1...6)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .vipiGlass(interactive: phase != .offline, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .disabled(phase == .offline)

                Button {
                    if showsStop {
                        onStop()
                    } else {
                        onSend(isWorking ? .followUp : .prompt)
                    }
                } label: {
                    Image(systemName: showsStop ? "stop.fill" : "arrow.up")
                        .font(.body.bold())
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .vipiGlass(
                            tint: showsStop ? VipiTheme.danger : trimmedDraft.isEmpty ? VipiTheme.secondary.opacity(0.2) : VipiTheme.accent,
                            interactive: true,
                            in: Circle()
                        )
                }
                .disabled(phase == .offline || (!isWorking && trimmedDraft.isEmpty))
                .accessibilityIdentifier(showsStop ? "chat.stop" : "chat.send")
                .accessibilityLabel(showsStop ? "Stop current run" : "Send message")
                .accessibilityHint(showsStop ? "Stops the active Pi response" : isWorking ? "Queues this message after the active response" : "Sends a prompt to Pi")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, queuedPrompts.isEmpty ? 9 : 7)
        .padding(.bottom, 7)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().overlay(VipiTheme.stroke) }
    }
}

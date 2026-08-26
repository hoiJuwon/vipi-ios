import SwiftUI

struct ComposerView: View {
    @Binding var draft: String
    let phase: SessionPhase
    let queuedPrompts: [QueuedPrompt]
    let annotations: [ChatAnnotation]
    let interaction: RemoteInteraction?
    let interactionSessionName: String?
    let onRemoveAnnotation: (String) -> Void
    let onRespondToInteraction: (RemoteInteraction, JSONValue) -> Void
    let onSend: (PromptDelivery) -> Void
    let onStop: () -> Void

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isWorking: Bool { phase == .working || phase == .waitingForInput }
    private var showsStop: Bool { isWorking && trimmedDraft.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let interaction {
                RemoteInteractionCard(
                    interaction: interaction,
                    sessionName: interactionSessionName
                ) { response in
                    onRespondToInteraction(interaction, response)
                }
                .id(interaction.requestID)
                .padding(.horizontal, 2)
                .padding(.bottom, 2)
            }

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

            ForEach(annotations) { annotation in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "quote.opening")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(VipiTheme.accent)
                        .padding(.top, 2)
                    Text(annotation.text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression))
                        .font(.caption)
                        .foregroundStyle(VipiTheme.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        onRemoveAnnotation(annotation.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .frame(width: 22, height: 22)
                    }
                    .foregroundStyle(VipiTheme.secondary)
                    .accessibilityLabel("Remove annotation")
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .background(VipiTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(VipiTheme.accent.opacity(0.24), lineWidth: 0.75)
                }
                .padding(.horizontal, 2)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chat.annotation")
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
                        .foregroundStyle(
                            showsStop ? Color.white : trimmedDraft.isEmpty ? VipiTheme.secondary : VipiTheme.accentForeground
                        )
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
        .padding(.top, queuedPrompts.isEmpty && annotations.isEmpty && interaction == nil ? 9 : 7)
        .padding(.bottom, 7)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().overlay(VipiTheme.stroke) }
    }
}

struct RemoteInteractionCard: View {
    let interaction: RemoteInteraction
    let sessionName: String?
    let respond: (JSONValue) -> Void
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(VipiTheme.danger)
                    .frame(width: 7, height: 7)
                Text(interaction.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VipiTheme.primary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if let sessionName {
                    Text(sessionName.components(separatedBy: " / ").last ?? sessionName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(VipiTheme.secondary)
                        .lineLimit(1)
                }
            }

            if let message = interaction.message, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(VipiTheme.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            controls
        }
        .padding(13)
        .vipiGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("interaction.card")
    }

    @ViewBuilder
    private var controls: some View {
        switch interaction.kind {
        case .confirm:
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Deny", role: .destructive) { respond(.bool(false)) }
                    .buttonStyle(.bordered)
                    .tint(VipiTheme.danger)
                Button("Allow") { respond(.bool(true)) }
                    .buttonStyle(.borderedProminent)
                    .tint(VipiTheme.danger)
            }
            .controlSize(.small)
        case .select:
            VStack(alignment: .leading, spacing: 7) {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(interaction.options ?? [], id: \.self) { option in
                            Button(option) { respond(.string(option)) }
                                .buttonStyle(.plain)
                                .font(.subheadline)
                                .foregroundStyle(VipiTheme.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(VipiTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                    }
                }
                .frame(maxHeight: 150)
                Button("Cancel", role: .cancel) { respond(.null) }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(VipiTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        case .input:
            HStack(alignment: .bottom, spacing: 8) {
                TextField(interaction.placeholder ?? "Response", text: $input, axis: .vertical)
                    .lineLimit(1...3)
                    .font(.subheadline)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(VipiTheme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(VipiTheme.stroke, lineWidth: 0.75)
                    }
                    .accessibilityIdentifier("interaction.input")
                Button {
                    respond(.string(input))
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(VipiTheme.danger, in: Circle())
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Submit")
                Button("Cancel", role: .cancel) { respond(.null) }
                    .font(.caption)
            }
        }
    }
}

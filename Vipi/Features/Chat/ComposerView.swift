import ImageIO
import PhotosUI
import SwiftUI
import UIKit

struct ComposerView: View {
    @Binding var draft: String
    let phase: SessionPhase
    let queuedPrompts: [QueuedPrompt]
    let annotations: [ChatAnnotation]
    let imageAttachments: [DraftImageAttachment]
    let interaction: RemoteInteraction?
    let interactionSessionName: String?
    let onRemoveAnnotation: (String) -> Void
    let onAddImage: (DraftImageAttachment) -> Void
    let onRemoveImage: (String) -> Void
    let onPhotoImportError: (String) -> Void
    let onRespondToInteraction: (RemoteInteraction, JSONValue) -> Void
    let onSend: (PromptDelivery) -> Void
    let onStop: () -> Void

    @State private var showsPhotoPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isWorking: Bool { phase == .working || phase == .waitingForInput }
    private var showsStop: Bool { isWorking && trimmedDraft.isEmpty && imageAttachments.isEmpty && interaction == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let interaction {
                RemoteInteractionCard(
                    interaction: interaction,
                    sessionName: interactionSessionName,
                    usesGlass: false
                ) { response in
                    onRespondToInteraction(interaction, response)
                }
                .id(interaction.requestID)

                Divider().overlay(VipiTheme.stroke)
            }

            if let first = queuedPrompts.first {
                HStack(spacing: 6) {
                    Text("Queued").foregroundStyle(VipiTheme.primary)
                    Text(first.text.isEmpty ? "Photo" : first.text).foregroundStyle(VipiTheme.secondary).lineLimit(1)
                    if queuedPrompts.count > 1 {
                        Text("+\(queuedPrompts.count - 1)").foregroundStyle(VipiTheme.secondary)
                    }
                }
                .font(.caption)
                .padding(.horizontal, 6)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chat.queue")
                .accessibilityLabel("Queued messages")
                .accessibilityValue("\(queuedPrompts.count)")
            }

            ForEach(annotations) { annotation in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "quote.opening")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(VipiTheme.secondary)
                        .padding(.top, 2)
                    Text(annotation.text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression))
                        .font(.caption)
                        .foregroundStyle(VipiTheme.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { onRemoveAnnotation(annotation.id) } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .frame(width: 28, height: 28)
                    }
                    .foregroundStyle(VipiTheme.secondary)
                    .accessibilityLabel("Remove annotation")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(VipiTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chat.annotation")
            }

            if !imageAttachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(imageAttachments) { attachment in
                            DraftImageThumbnail(attachment: attachment) {
                                onRemoveImage(attachment.id)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("chat.imageAttachments")
            }

            if interaction == nil {
                VStack(alignment: .leading, spacing: 0) {
                    TextField(phase == .offline ? "Reconnecting session…" : "Message Pi…", text: $draft, axis: .vertical)
                        .accessibilityIdentifier("chat.composer")
                        .accessibilityLabel("Message Pi")
                        .lineLimit(1...6)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .disabled(phase == .offline)

                    HStack(alignment: .center, spacing: 8) {
                    Menu {
                        Button {
                            insertGoalCommand()
                        } label: {
                            Label("Goal", systemImage: "scope")
                        }
                        .disabled(isWorking)
                        .accessibilityIdentifier("chat.add.goal")

                        Button {
                            showsPhotoPicker = true
                        } label: {
                            Label("Photo Library", systemImage: "photo.on.rectangle")
                        }
                        .disabled(imageAttachments.count >= 4)
                        .accessibilityIdentifier("chat.add.photo")
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.medium))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .foregroundStyle(VipiTheme.primary)
                    .disabled(phase == .offline)
                    .accessibilityIdentifier("chat.add")
                    .accessibilityLabel("Add to message")

                    Spacer(minLength: 8)

                    Button {
                        if showsStop { onStop() } else { onSend(isWorking ? .followUp : .prompt) }
                    } label: {
                        Image(systemName: showsStop ? "stop.fill" : "arrow.up")
                            .font(.body.bold())
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .tint(VipiTheme.primaryAction)
                    .foregroundStyle(VipiTheme.primaryActionForeground)
                    .disabled(phase == .offline || (!isWorking && trimmedDraft.isEmpty && imageAttachments.isEmpty))
                    .accessibilityIdentifier(showsStop ? "chat.stop" : "chat.send")
                    .accessibilityLabel(showsStop ? "Stop current run" : "Send message")
                        .accessibilityHint(showsStop ? "Stops the active Pi response" : isWorking ? "Queues this message after the active response" : "Sends a prompt to Pi")
                    }
                }
            }
        }
        .padding(10)
        .vipiGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 7)
        .photosPicker(
            isPresented: $showsPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: max(1, 4 - imageAttachments.count),
            matching: .images,
            preferredItemEncoding: .automatic
        )
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await importPhotos(items) }
        }
    }

    private func insertGoalCommand() {
        if trimmedDraft.isEmpty {
            draft = "/goal "
        } else if !trimmedDraft.hasPrefix("/goal") {
            draft = "/goal \(draft)"
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        defer { selectedPhotoItems = [] }
        let availableSlots = max(0, 4 - imageAttachments.count)
        for item in items.prefix(availableSlots) {
            do {
                guard let sourceData = try await item.loadTransferable(type: Data.self),
                      let jpegData = await Task.detached(priority: .userInitiated, operation: {
                          PhotoAttachmentProcessor.jpegData(from: sourceData)
                      }).value else {
                    throw PhotoAttachmentError.unsupported
                }
                onAddImage(DraftImageAttachment(data: jpegData))
            } catch {
                onPhotoImportError(error.localizedDescription)
            }
        }
    }
}

private struct DraftImageThumbnail: View {
    let attachment: DraftImageAttachment
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = UIImage(data: attachment.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(.black.opacity(0.68), in: Circle())
            }
            .offset(x: 5, y: -5)
            .accessibilityLabel("Remove photo")
        }
        .padding(.top, 5)
        .padding(.trailing, 5)
    }
}

enum PhotoAttachmentProcessor {
    static func jpegData(from data: Data, maxPixelSize: Int = 2_048, quality: CGFloat = 0.82) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: quality)
    }
}

private enum PhotoAttachmentError: LocalizedError {
    case unsupported
    var errorDescription: String? { "The selected photo could not be prepared." }
}

struct RemoteInteractionCard: View {
    let interaction: RemoteInteraction
    let sessionName: String?
    var usesGlass = true
    let respond: (JSONValue) -> Void
    @State private var input = ""

    var body: some View {
        Group {
            if usesGlass {
                content
                    .padding(14)
                    .vipiGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                content.padding(4)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("interaction.card")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
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
    }

    @ViewBuilder
    private var controls: some View {
        switch interaction.kind {
        case .confirm:
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Deny") { respond(.bool(false)) }
                    .buttonStyle(.bordered)
                    .tint(VipiTheme.secondary)
                    .frame(minHeight: 44)
                Button("Allow") { respond(.bool(true)) }
                    .buttonStyle(.borderedProminent)
                    .tint(VipiTheme.primary)
                    .foregroundStyle(VipiTheme.canvas)
                    .frame(minHeight: 44)
            }
        case .select:
            VStack(alignment: .leading, spacing: 7) {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(interaction.options ?? [], id: \.self) { option in
                            Button(option) { respond(.string(option)) }
                                .buttonStyle(.plain)
                                .font(.subheadline)
                                .foregroundStyle(VipiTheme.primary)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(.horizontal, 10)
                                .background(VipiTheme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        }
                    }
                }
                .frame(maxHeight: 158)
                Button("Cancel", role: .cancel) { respond(.null) }
                    .font(.subheadline)
                    .foregroundStyle(VipiTheme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
            }
        case .input:
            HStack(alignment: .bottom, spacing: 8) {
                TextField(interaction.placeholder ?? "Response", text: $input, axis: .vertical)
                    .lineLimit(1...3)
                    .font(.subheadline)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 10)
                    .background(VipiTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityIdentifier("interaction.input")
                Button {
                    respond(.string(input))
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.caption.bold())
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .tint(VipiTheme.primaryAction)
                .foregroundStyle(VipiTheme.primaryActionForeground)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Submit")
                Button("Cancel", role: .cancel) { respond(.null) }
                    .font(.subheadline)
                    .frame(minHeight: 44)
            }
        }
    }
}

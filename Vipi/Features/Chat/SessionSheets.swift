import SwiftUI

struct SessionDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: RemoteSession

    var body: some View {
        NavigationStack {
            List {
                Section("Session") {
                    LabeledContent("Name", value: session.name)
                    LabeledContent("Workspace", value: session.cwd)
                    LabeledContent("Status") { StatusPill(phase: session.phase) }
                }
                Section("Model") {
                    LabeledContent("Model", value: session.model)
                    LabeledContent("Thinking", value: session.thinkingLevel)
                    LabeledContent("Context", value: "\(session.contextPercent)%")
                }
                Section("Host runtime") {
                    LabeledContent("tmux", value: "\(session.tmux.session):\(session.tmux.window)")
                    LabeledContent("Pane", value: session.tmux.paneID)
                }
            }
            .navigationTitle("Session details")
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct BranchesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let nodes: [BranchNode]

    var body: some View {
        NavigationStack {
            List(nodes) { node in
                HStack(spacing: 12) {
                    Image(systemName: node.isActive ? "circle.inset.filled" : "circle")
                        .foregroundStyle(node.isActive ? VipiTheme.accent : VipiTheme.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(node.title).font(.body.weight(node.isActive ? .semibold : .regular))
                        if let subtitle = node.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if node.isActive { Text("Current").font(.caption).foregroundStyle(VipiTheme.accent) }
                }
                .padding(.leading, CGFloat(node.depth * 16))
            }
            .navigationTitle("Conversation branches")
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }
}

import SwiftUI

struct ActivityView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ZStack {
            VipiBackdrop()
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.activityItems) { item in
                        HStack(alignment: .top, spacing: 13) {
                            ZStack {
                                Circle().fill(item.status.color.opacity(0.13)).frame(width: 42, height: 42)
                                Image(systemName: icon(item.status)).foregroundStyle(item.status.color)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(item.title).font(.body.bold()); Spacer(); Text(item.date, style: .relative).font(.caption2).foregroundStyle(VipiTheme.secondary) }
                                Text(item.sessionName).font(.caption.weight(.medium)).foregroundStyle(VipiTheme.accent)
                                Text(item.detail).font(.subheadline).foregroundStyle(VipiTheme.secondary)
                            }
                        }
                        .padding(15).vipiCard()
                    }
                }.padding(16)
            }
        }
        .navigationTitle("Activity")
    }

    private func icon(_ status: SessionPhase) -> String {
        switch status { case .working: "gearshape.2.fill"; case .waitingForInput: "questionmark.bubble.fill"; case .failed: "exclamationmark.triangle.fill"; default: "checkmark.circle.fill" }
    }
}

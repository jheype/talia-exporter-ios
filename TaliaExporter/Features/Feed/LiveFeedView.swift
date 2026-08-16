import SwiftUI

struct LiveFeedView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppModel
    @State private var searchText = ""

    private var filteredMessages: [CapturedMessage] {
        guard !searchText.isEmpty else { return appModel.messages }
        return appModel.messages.filter {
            $0.groupName.localizedCaseInsensitiveContains(searchText)
                || $0.sender.localizedCaseInsensitiveContains(searchText)
                || $0.body.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredMessages) { message in
                MessageRow(message: message)
            }
            .listStyle(.plain)
            .navigationTitle("Live feed")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search captured messages")
            .refreshable {
                await appModel.refreshMessages()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    LivePill(
                        title: appModel.compactCaptureStatus,
                        colour: appModel.captureStatusColour
                    )
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if filteredMessages.isEmpty {
                    EmptyStateView(
                        title: "No messages found",
                        message: "Try a different sender, group or message.",
                        systemImage: "text.magnifyingglass"
                    )
                }
            }
        }
    }
}

private struct MessageRow: View {
    let message: CapturedMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(message.groupName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.taliaBlue)

                Spacer()

                Text(message.time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(message.sender)
                .font(.subheadline.weight(.semibold))

            Text(message.displayBody)
                .font(.body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if message.isEdited && !message.isRevoked {
                Text("Edited")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if message.containsPrice {
                Label("Price detected", systemImage: "sterlingsign.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.taliaNavy)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.taliaBlue.opacity(0.10))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 9)
    }
}

#Preview {
    LiveFeedView()
        .environmentObject(AppModel.preview())
}

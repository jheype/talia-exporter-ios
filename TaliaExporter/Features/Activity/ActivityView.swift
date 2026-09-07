import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var showLiveFeed = false
    @State private var search = ""
    @State private var selectedKind: CaptureEvent.Kind?

    private var filteredEvents: [CaptureEvent] {
        appModel.events.filter { event in
            (selectedKind == nil || event.kind == selectedKind) &&
            (search.isEmpty || event.groupName.localizedCaseInsensitiveContains(search) || event.detail.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Filter", selection: $selectedKind) {
                        Text("All").tag(Optional<CaptureEvent.Kind>.none)
                        ForEach(CaptureEvent.Kind.allCases) { kind in
                            Text(kind.rawValue).tag(Optional(kind))
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section {
                    Button { showLiveFeed = true } label: {
                        Label("Open live feed", systemImage: "text.bubble")
                    }
                }
                Section("Recent") {
                    if filteredEvents.isEmpty {
                        EmptyStateView(
                            title: "No matching activity",
                            message: "Try another filter to see recent capture events.",
                            systemImage: "line.3.horizontal.decrease.circle"
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(filteredEvents) { event in
                            ActivityDetailRow(event: event)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .taliaSurface()
            .navigationTitle("Activity")
            .searchable(text: $search, prompt: "Search activity")
            .sheet(isPresented: $showLiveFeed) { LiveFeedView() }
            .refreshable {
                await appModel.refreshEvents()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    LivePill(
                        title: appModel.compactCaptureStatus,
                        colour: appModel.captureStatusColour
                    )
                }
            }
        }
    }
}

private struct ActivityDetailRow: View {
    let event: CaptureEvent

    private var symbol: String {
        switch event.kind {
        case .captured: "text.bubble.fill"
        case .synchronised: "arrow.triangle.2.circlepath"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private var colour: Color {
        switch event.kind {
        case .captured: .taliaAccent
        case .synchronised: .taliaLive
        case .warning: .orange
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(colour)
                .frame(width: 34, height: 34)
                .background(colour.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(event.groupName)
                        .font(.body.weight(.semibold))

                    Spacer()

                    Text(event.time)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Text(event.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(event.kind.rawValue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(colour)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(colour.opacity(0.10))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 5)
    }
}

#Preview {
    ActivityView()
        .environmentObject(AppModel.preview())
}

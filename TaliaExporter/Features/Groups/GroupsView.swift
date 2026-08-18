import SwiftUI

struct GroupsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var searchText = ""

    private var filteredGroups: [ExportGroup] {
        guard !searchText.isEmpty else { return appModel.groups }
        return appModel.groups.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.category.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(filteredGroups) { group in
                        GroupSelectionRow(
                            group: group,
                            isRetrying: appModel.historyRetryingGroupIDs.contains(group.id),
                            onToggle: { appModel.toggleGroup(group) },
                            onRetry: {
                                Task { await appModel.retryHistorySync(for: group) }
                            }
                        )
                    }
                } header: {
                    Text("Available groups")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Groups")
            .searchable(text: $searchText, prompt: "Search groups")
            .refreshable {
                await appModel.refreshGroups()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Select all", systemImage: "checkmark.circle") {
                            appModel.selectAllGroups()
                        }

                        Button("Clear selection", systemImage: "circle") {
                            appModel.clearGroupSelection()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                selectionSummary
            }
        }
    }

    private var selectionSummary: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.taliaBlue)

            Text("\(appModel.selectedGroupsDescription) selected")
                .font(.subheadline.weight(.semibold))

            Spacer()

            LivePill(
                title: appModel.compactCaptureStatus,
                colour: appModel.captureStatusColour
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

private struct GroupSelectionRow: View {
    let group: ExportGroup
    let isRetrying: Bool
    let onToggle: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    GroupAvatar(initials: group.initials)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)

                        HStack(spacing: 5) {
                            Text(group.category)
                            Text("•")
                            Text(group.lastActivity)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: group.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(group.isSelected ? Color.taliaBlue : Color.secondary.opacity(0.45))
                        .contentTransition(.symbolEffect(.replace))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.name), \(group.isSelected ? "selected" : "not selected")")
            .accessibilityHint("Double tap to toggle capture for this group")

            if group.isSelected {
                GroupHistoryProgress(
                    group: group,
                    isRetrying: isRetrying,
                    onRetry: onRetry
                )
                .padding(.leading, 52)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct GroupHistoryProgress: View {
    let group: ExportGroup
    let isRetrying: Bool
    let onRetry: () -> Void

    private var state: GroupHistorySyncState { group.effectiveHistorySyncState }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if state.isActive {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Color.taliaBlue)
            } else if state != .complete {
                ProgressView(value: 0)
                    .progressViewStyle(.linear)
                    .tint(
                        state == .waitingForAnchor || state == .availabilityLimited || state == .unknown
                            ? Color.orange
                            : Color.red
                    )
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColour)

                    Text(statusDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if state.canRetry {
                    Button(action: onRetry) {
                        if isRetrying {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .disabled(isRetrying)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusTitle: String {
        switch state {
        case .idle, .queued:
            "History queued"
        case .requesting:
            "Requesting older messages"
        case .receiving:
            "Capturing message history"
        case .waitingForAnchor:
            "Waiting for a recent message"
        case .complete:
            "Latest available batch captured"
        case .stalled:
            "Older history paused"
        case .availabilityLimited:
            "Older history is phone-limited"
        case .failed:
            "History capture failed"
        case .unknown:
            "History status unavailable"
        }
    }

    private var statusDetail: String {
        if let error = group.historySyncLastError,
           state == .waitingForAnchor || state == .stalled || state == .availabilityLimited || state == .failed {
            return "\(group.capturedTextDescription). \(error)"
        }
        let batches = group.historyBatchCount ?? 0
        let oldest = group.historyOldestMessageAt?.formatted(
            date: .abbreviated,
            time: .shortened
        ) ?? "not available yet"
        if state == .complete {
            return "\(group.capturedTextDescription) · oldest \(oldest). Live capture stays on."
        }
        return "\(group.capturedTextDescription) · \(batches) \(batches == 1 ? "batch" : "batches") · oldest \(oldest)"
    }

    private var statusColour: Color {
        switch state {
        case .complete:
            .taliaLive
        case .waitingForAnchor, .stalled, .availabilityLimited, .unknown:
            .orange
        case .failed:
            .red
        default:
            .taliaBlue
        }
    }
}

#Preview {
    GroupsView()
        .environmentObject(AppModel.preview())
}

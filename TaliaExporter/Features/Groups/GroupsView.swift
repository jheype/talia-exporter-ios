import SwiftUI

struct GroupsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var searchText = ""

    private var filteredGroups: [ExportGroup] {
        guard !searchText.isEmpty else { return appModel.groups }
        return appModel.groups.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.category.localizedCaseInsensitiveContains(searchText)
                || $0.effectiveFunction.title.localizedCaseInsensitiveContains(searchText)
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
                } footer: {
                    Text("Select a group to capture it, then choose whether its live messages feed UK Chats, Tasks or the operations log.")
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
            HStack(spacing: 8) {
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

                        Label(group.effectiveFunction.shortTitle, systemImage: group.effectiveFunction.systemImage)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(functionColour)
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

                NavigationLink {
                    GroupRoutingView(groupID: group.id)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.taliaBlue)
                        .frame(width: 36, height: 36)
                        .background(Color.taliaBlue.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Configure \(group.name)")
            }

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

    private var functionColour: Color {
        switch group.effectiveFunction {
        case .exporterMentions: .taliaBlue
        case .tasks: .taliaLive
        case .logs: .orange
        }
    }
}

private struct GroupRoutingView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    let groupID: String

    @State private var function: GroupFunction = .exporterMentions
    @State private var botFeedbackEnabled = false
    @State private var botRemindersEnabled = false
    @State private var botDestinationID = ""
    @State private var expectedRevision: Int64 = 1
    @State private var didLoad = false

    private var group: ExportGroup? {
        appModel.groups.first(where: { $0.id == groupID })
    }

    private var isSaving: Bool {
        appModel.routingSavingGroupIDs.contains(groupID)
    }

    var body: some View {
        Form {
            Section {
                Picker("Group function", selection: $function) {
                    ForEach(GroupFunction.allCases) { option in
                        Label(option.title, systemImage: option.systemImage)
                            .tag(option)
                    }
                }
                .pickerStyle(.inline)

                Label(function.detail, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Message routing")
            } footer: {
                Text("The function is account-scoped. Changing it affects new live messages only; retained history never executes task or log commands.")
            }

            if function != .exporterMentions {
                Section {
                    Toggle("Queue WhatsApp acknowledgements", isOn: $botFeedbackEnabled)
                        .tint(Color.taliaBlue)

                    if function == .tasks {
                        Toggle("Queue inactive-task reminders", isOn: $botRemindersEnabled)
                            .tint(Color.taliaBlue)
                    }

                    TextField("Meta group destination ID (optional)", text: $botDestinationID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("WhatsApp bot readiness")
                } footer: {
                    Text("Replies are stored safely now. Delivery starts only after an eligible official Meta Groups API number and destination are configured; the app does not use unofficial WhatsApp automation.")
                }
            }

            Section("Capture") {
                LabeledContent("Selected", value: group?.isSelected == true ? "Yes" : "No")
                LabeledContent("Live capture", value: appModel.captureEnabled ? "Enabled" : "Paused")
                LabeledContent("Configuration", value: "Revision \(group?.effectiveFunctionRevision ?? 1)")
            }
        }
        .navigationTitle(group?.name ?? "Group function")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        let saved = await appModel.saveGroupRouting(
                            groupID: groupID,
                            function: function,
                            botFeedbackEnabled: botFeedbackEnabled,
                            botRemindersEnabled: botRemindersEnabled,
                            botDestinationID: botDestinationID,
                            expectedRevision: expectedRevision
                        )
                        if saved {
                            dismiss()
                        } else if let latestRevision = group?.effectiveFunctionRevision {
                            expectedRevision = latestRevision
                        }
                    }
                }
                .disabled(group == nil || isSaving)
            }
        }
        .overlay {
            if isSaving {
                ProgressView("Saving function…")
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .onChange(of: function) { _, newValue in
            if newValue == .exporterMentions {
                botFeedbackEnabled = false
                botRemindersEnabled = false
                botDestinationID = ""
            } else if newValue == .logs {
                botRemindersEnabled = false
            }
        }
        .onAppear(perform: loadCurrentValues)
    }

    private func loadCurrentValues() {
        guard !didLoad, let group else { return }
        didLoad = true
        function = group.effectiveFunction
        botFeedbackEnabled = group.effectiveBotFeedbackEnabled
        botRemindersEnabled = group.effectiveBotRemindersEnabled
        botDestinationID = group.botDestinationID ?? ""
        expectedRevision = group.effectiveFunctionRevision
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

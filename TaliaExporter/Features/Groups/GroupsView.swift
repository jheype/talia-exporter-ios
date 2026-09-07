import SwiftUI

struct GroupsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var searchText = ""
    @State private var selectedOnly = false
    @State private var path: [String] = []

    private var filteredGroups: [ExportGroup] {
        let visible = appModel.groups.filter { !selectedOnly || $0.isSelected }
        guard !searchText.isEmpty else { return visible }
        return visible.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.category.localizedCaseInsensitiveContains(searchText)
                || $0.effectiveFunction.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Picker("Show groups", selection: $selectedOnly) {
                        Text("All groups").tag(false)
                        Text("Selected").tag(true)
                    }.pickerStyle(.segmented)
                }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                Section {
                    ForEach(filteredGroups) { group in
                        GroupSelectionRow(group: group,
                            onToggle: { appModel.toggleGroup(group) },
                            onConfigure: { path.append(group.id) })
                    }
                } header: {
                    Text("Available groups")
                } footer: {
                    Text("Select a group to capture it, then choose whether its live messages feed UK Chats, Tasks, the operations log or your private notes.")
                }
            }
            .listStyle(.insetGrouped)
            .taliaSurface()
            .navigationTitle("Groups")
            .navigationDestination(for: String.self) { GroupRoutingView(groupID: $0) }
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
                .foregroundStyle(Color.taliaAccent)

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
    let onToggle: () -> Void
    let onConfigure: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onConfigure) {
                HStack(spacing: 12) {
                    GroupAvatar(initials: group.initials, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.name).font(.subheadline.weight(.semibold))
                            .lineLimit(1).foregroundStyle(Color.taliaAccent)
                        Text(group.effectiveFunction.shortTitle).font(.caption).foregroundStyle(.secondary)
                        Text("Last activity \(group.lastActivity)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, minHeight: 66, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).layoutPriority(1)
            Button(action: onToggle) {
                Image(systemName: group.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(group.isSelected ? Color.taliaLive : .taliaSecondaryText)
                    .frame(width: 44, height: 44)
            }.buttonStyle(.plain).fixedSize()
                .accessibilityLabel("\(group.isSelected ? "Stop capturing" : "Capture") \(group.name)")
            Button(action: onConfigure) { Image(systemName: "chevron.right").font(.caption).frame(width: 24, height: 44) }
                .buttonStyle(.plain).fixedSize().foregroundStyle(.secondary).accessibilityLabel("Configure \(group.name)")
        }.padding(.vertical, 4)
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
                Text("Changes apply to new messages. Existing history stays available.")
            }

            if function == .tasks || function == .logs {
                Section {
                    Toggle("Queue WhatsApp acknowledgements", isOn: $botFeedbackEnabled)
                        .tint(Color.taliaAccent)

                    if function == .tasks {
                        Toggle("Queue inactive-task reminders", isOn: $botRemindersEnabled)
                            .tint(Color.taliaAccent)
                    }

                    TextField("Meta group destination ID (optional)", text: $botDestinationID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("WhatsApp replies")
                } footer: {
                    Text("Replies require a configured WhatsApp delivery destination. Until then, they remain queued.")
                }
            }

            Section("Capture") {
                LabeledContent("Selected", value: group?.isSelected == true ? "Yes" : "No")
                LabeledContent("Live capture", value: appModel.captureEnabled ? "Enabled" : "Paused")
                if let group {
                    GroupHistoryProgress(group: group, isRetrying: appModel.historyRetryingGroupIDs.contains(group.id)) {
                        Task { await appModel.retryHistorySync(for: group) }
                    }
                }
            }
        }
        .taliaSurface()
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
                        } else {
                            didLoad = false
                            loadCurrentValues()
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
            if newValue == .exporterMentions || newValue == .personalNotes {
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
                    .tint(Color.taliaAccent)
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
            .taliaAccent
        }
    }
}

#Preview {
    GroupsView()
        .environmentObject(AppModel.preview())
}

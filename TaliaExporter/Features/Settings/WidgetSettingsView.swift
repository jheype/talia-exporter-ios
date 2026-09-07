import SwiftUI

struct WidgetSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var draft = WidgetPreferences.default
    @State private var didLoad = false
    @State private var isSaving = false

    private var taskGroups: [ExportGroup] {
        appModel.groups.filter { $0.effectiveFunction == .tasks }
    }

    private var messageGroups: [ExportGroup] {
        appModel.groups.filter {
            $0.isSelected && ($0.effectiveFunction == .tasks
                || (draft.includeLogs && $0.effectiveFunction == .logs))
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Task view", selection: $draft.taskScope) {
                    ForEach(WidgetTaskScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }

                if draft.taskScope == .mine {
                    TextField("Exact WhatsApp assignee name", text: $draft.assignee)
                        .textInputAutocapitalization(.words)
                }

                TextField("Project (optional)", text: $draft.project)

                Picker("Priority", selection: $draft.priority) {
                    Text("All priorities").tag("all")
                    Text("Urgent").tag("urgent")
                    Text("High").tag("high")
                    Text("Medium").tag("medium")
                    Text("Low").tag("low")
                }

                Picker("Task group", selection: $draft.taskGroupJID) {
                    Text("All task groups").tag("")
                    ForEach(taskGroups) { group in
                        Text(group.name).tag(group.id)
                    }
                }
            } header: {
                Text("Task progress widget")
            } footer: {
                if draft.taskScope == .mine && draft.assignee.isEmpty {
                    Text("Enter the assignee name exactly as it appears in WhatsApp to use My tasks.")
                }
            }

            Section {
                Picker("Message group", selection: $draft.messageGroupJID) {
                    Text("All task and log groups").tag("")
                    ForEach(messageGroups) { group in
                        Text(group.name).tag(group.id)
                    }
                }

                Toggle("Include log-group messages", isOn: $draft.includeLogs)
                    .tint(Color.taliaAccent)
            } header: {
                Text("Messages widget")
            } footer: {
                Text("Only live messages captured after a group is configured are shown.")
            }

            Section {
                Picker("Reporting period", selection: $draft.ukChatsPeriod) {
                    ForEach(WidgetUKChatsPeriod.allCases) { period in
                        Text(period.title).tag(period)
                    }
                }
            } header: {
                Text("UK Chats coverage widget")
            } footer: {
                Text("Shows captured messages, currently active UK Chats groups and discarded messages for the selected rolling period.")
            }

            Section("Privacy") {
                Toggle("Show task titles", isOn: $draft.showTaskTitles)
                    .tint(Color.taliaAccent)

                Toggle("Show message text", isOn: $draft.showMessageText)
                    .tint(Color.taliaAccent)

                Label(
                    "Choose what appears on your Home Screen. Saved widget content is cleared when you sign out or change accounts.",
                    systemImage: "lock.shield"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("Refresh") {
                LabeledContent {
                    Text(appModel.widgetLastRefreshedAt?.relativeDescription ?? "Not refreshed yet")
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Last snapshot", systemImage: "clock.arrow.circlepath")
                }

                Button {
                    Task { await save() }
                } label: {
                    Label("Save and refresh widgets", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isSaving || (draft.taskScope == .mine && draft.assignee.isEmpty))
            }

            Section {
                Label("Add Talia Tasks, Talia Messages or UK Chats Coverage from the iOS widget gallery after saving.", systemImage: "rectangle.3.group")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .taliaSurface()
        .navigationTitle("Widgets")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isSaving {
                ProgressView("Refreshing widgets…")
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            draft = appModel.widgetPreferences
        }
        .onChange(of: draft.includeLogs) { _, includesLogs in
            guard !includesLogs,
                  appModel.groups.first(where: { $0.id == draft.messageGroupJID })?.effectiveFunction == .logs
            else { return }
            draft.messageGroupJID = ""
        }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        await appModel.saveWidgetPreferences(draft)
        draft = appModel.widgetPreferences
        isSaving = false
    }
}

#Preview {
    NavigationStack {
        WidgetSettingsView()
            .environmentObject(AppModel.preview())
    }
}

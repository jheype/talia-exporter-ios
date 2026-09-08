import SwiftUI

struct CalendarSettingsView: View {
    @ObservedObject var controller: CalendarSyncController
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                Toggle("Sync with Apple Calendar", isOn: Binding(
                    get: { controller.preferences.enabled },
                    set: { enabled in Task { await controller.setEnabled(enabled) } }
                ))
                .disabled(controller.isChangingAccess)
                if controller.isChangingAccess { ProgressView("Updating Calendar access…") }
            } footer: {
                Text("Add upcoming deadlines as events with an alert when they are due. Turning sync off removes the events added by Talia.")
            }

            if controller.preferences.enabled {
                Section("Destination") {
                    Picker("Calendar", selection: setting(\.calendarID)) {
                        if !controller.destinations.contains(where: { $0.id == controller.preferences.calendarID }) {
                            Text("Choose a calendar").tag(controller.preferences.calendarID)
                        }
                        ForEach(controller.destinations) { destination in
                            Text("\(destination.title) · \(destination.account)").tag(destination.id)
                        }
                    }
                }
                Section {
                    Toggle("Tasks", isOn: setting(\.includeTasks))
                    if controller.preferences.includeTasks {
                        Picker("Assigned to", selection: setting(\.assignee)) {
                            Text("All tasks").tag("")
                            ForEach(assignees, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Toggle("My Notes", isOn: setting(\.includeNotes))
                } header: { Text("Include") } footer: {
                    Text("Only your personal notes are included. Their first line appears in Calendar and its alerts. Choose a private calendar if you do not want others to see it.")
                }
                Section("Synchronisation") {
                    LabeledContent("Alert", value: "At the deadline")
                    LabeledContent("Upcoming events", value: String(controller.eventCount))
                    LabeledContent("Last synced", value: controller.lastSyncedAt?.relativeDescription ?? "Not yet")
                    Button {
                        Task { await controller.refresh(force: true) }
                    } label: {
                        HStack {
                            Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if controller.isSyncing { ProgressView() }
                        }
                    }.disabled(controller.isSyncing || controller.isChangingAccess)
                }
            }

            if let message = controller.errorMessage {
                Section {
                    Text(message).foregroundStyle(.red)
                    if controller.access == .denied {
                        Button("Open iPhone Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                }
            }
            Section {
                Text("Change deadlines in Talia. Calendar edits do not change your tasks or notes and may be replaced on the next sync.")
                Text("Sync runs while Talia is open and when iOS allows background refresh. Saved alerts can appear while Talia is closed. Enable notifications for Calendar in iPhone Settings.")
            }.font(.footnote).foregroundStyle(.secondary)
        }
        .tint(Color.taliaAccent)
        .taliaSurface()
        .navigationTitle("Apple Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await controller.loadAccess()
            await workspace.loadAssignees()
        }
    }

    private var assignees: [String] {
        Array(Set(workspace.assignees + (controller.preferences.assignee.isEmpty ? [] : [controller.preferences.assignee]))).sorted()
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<CalendarPreferences, Value>) -> Binding<Value> {
        Binding(get: { controller.preferences[keyPath: keyPath] }, set: { value in
            Task { await controller.update { $0[keyPath: keyPath] = value } }
        })
    }
}

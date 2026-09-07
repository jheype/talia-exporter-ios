import SwiftUI

struct TaskDetailView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID
    @State private var section = DetailSection.checklist
    @State private var newItem = ""
    @State private var newNote = ""
    @State private var showEdit = false
    @State private var showDelete = false
    @State private var itemToDelete: WorkItem?

    enum DetailSection: String, CaseIterable, Identifiable {
        case checklist = "Checklist", messages = "Messages", history = "History"
        var id: Self { self }
    }

    var body: some View {
        Group {
            if let task = store.detail, task.id == taskID {
                content(task)
            } else if store.loading.contains("detail") {
                ProgressView("Loading task…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack {
                    WorkEmptyState(title: "Task unavailable", message: "Refresh to try again.", symbol: "checklist")
                    Button("Try again") { Task { await store.openTask(taskID) } }
                }
            }
        }
        .background(Color.taliaBackground)
        .navigationTitle(store.detail?.id == taskID ? (store.detail?.publicID ?? "Task") : "Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let task = store.detail, task.id == taskID {
                    Menu {
                        Button("Edit details", systemImage: "slider.horizontal.3") { showEdit = true }
                        if !task.status.isClosed {
                            Button("Mark blocked", systemImage: "exclamationmark.circle") {
                                Task { await store.updateTask(task, fields: ["status": .string("blocked")]) }
                            }
                        } else {
                            Button("Reopen task", systemImage: "arrow.uturn.backward") {
                                Task { await store.updateTask(task, fields: ["status": .string("todo")]) }
                            }
                        }
                        Button("Delete task", systemImage: "trash", role: .destructive) { showDelete = true }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    .disabled(store.isMutating).accessibilityLabel("Task actions")
                }
            }
        }
        .task(id: taskID) { await store.openTask(taskID) }
        .refreshable { await store.openTask(taskID) }
        .sheet(isPresented: $showEdit) {
            if let task = store.detail { EditTaskView(task: task) }
        }
        .confirmationDialog("Delete this task?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete task", role: .destructive) {
                guard let task = store.detail else { return }
                Task { if await store.deleteTask(task) { dismiss() } }
            }
        } message: { Text("This removes the task from the shared workspace.") }
        .confirmationDialog("Delete checklist item?", isPresented: Binding(
            get: { itemToDelete != nil }, set: { if !$0 { itemToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete item", role: .destructive) {
                guard let task = store.detail, let item = itemToDelete else { return }
                Task { await store.deleteItem(item, from: task); itemToDelete = nil }
            }
        }
    }

    private func content(_ task: WorkTask) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(task.title).font(.largeTitle.bold()).tracking(-0.7)
                Text("\(task.sourceGroupName) · \(task.sourceSenderName)")
                    .font(.subheadline).foregroundStyle(Color.taliaSecondaryText)
                if !task.description.isEmpty { Text(task.description).font(.body).textSelection(.enabled) }
                HStack {
                    Menu {
                        ForEach(WorkStatus.allCases) { status in
                            Button(status.title) { Task { await store.updateTask(task, fields: ["status": .string(status.rawValue)]) } }
                        }
                    } label: { Label(task.status.title, systemImage: "chevron.down") }
                    .buttonStyle(TaliaSecondaryButtonStyle()).disabled(store.isMutating)
                    WorkPriorityLabel(priority: task.priority)
                    Spacer()
                }
                Button { showEdit = true } label: {
                    VStack(spacing: 12) {
                        LabeledContent("Assignee", value: task.assigneeName ?? "Unassigned")
                        if let due = task.dueAt {
                            LabeledContent("Due", value: due.formatted(date: .abbreviated, time: .shortened))
                        } else { LabeledContent("Due", value: "No due date") }
                    }.font(.subheadline).foregroundStyle(Color.taliaAccent).taliaCard()
                }.buttonStyle(.plain)
                Picker("Task information", selection: $section) {
                    ForEach(DetailSection.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                switch section {
                case .checklist: checklist(task)
                case .messages: messages(task)
                case .history: history(task)
                }
            }.padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            if section == .checklist && !task.status.isClosed {
                Button { Task { await store.updateTask(task, fields: ["status": .string("done")]) } } label: {
                    if store.isMutating { ProgressView().tint(Color.taliaOnAccent) }
                    else { Text("Mark as done") }
                }
                .buttonStyle(TaliaPrimaryButtonStyle()).disabled(store.isMutating)
                .padding(16).background(Color.taliaBackground)
            }
        }
    }

    private func checklist(_ task: WorkTask) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(task.items.isEmpty ? "Progress" : "\(task.completedItems) of \(task.items.count) complete").font(.headline)
                Spacer()
                Text("\(task.progress)%").font(.subheadline).foregroundStyle(.secondary)
            }
            ProgressView(value: task.progressFraction).tint(Color.taliaAccent)
            if task.items.isEmpty {
                Text("No checklist yet. Add the first item below.").foregroundStyle(.secondary)
            }
            ForEach(task.items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Button { Task { await store.setItem(item, on: task, done: item.status != "done") } } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.status == "done" ? "checkmark.circle.fill" : "circle")
                                .font(.title3).foregroundStyle(item.status == "done" ? Color.taliaLive : .taliaAccent)
                            Text(String(format: "%02d", item.position)).font(.caption).foregroundStyle(.secondary).padding(.top, 3)
                            Text(item.body).font(.body).foregroundStyle(Color.taliaAccent)
                                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(minHeight: 44, alignment: .center).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(store.isMutating || task.status.isClosed)
                        .accessibilityLabel("\(item.body), \(item.status == "done" ? "complete" : "incomplete")")
                    if !task.status.isClosed {
                        Button { itemToDelete = item } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                            .foregroundStyle(.secondary).disabled(store.isMutating).accessibilityLabel("Remove \(item.body)")
                    }
                }
                Divider()
            }
            if !task.status.isClosed && task.items.count < 50 {
                HStack {
                    TextField("Add a checklist item…", text: $newItem, axis: .vertical).lineLimit(1...3)
                    Button { Task { if await store.addItem(newItem, to: task) { newItem = "" } } } label: {
                        Image(systemName: "plus.circle.fill").font(.title2).frame(width: 44, height: 44)
                    }.disabled(store.isMutating || newItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newItem.count > 500)
                        .accessibilityLabel("Add checklist item")
                }.taliaCard(padding: 12)
            }
        }
    }

    private func messages(_ task: WorkTask) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(task.messages) { message in WorkMessageCard(message: message) }
            if task.messages.isEmpty {
                WorkEmptyState(title: "No attached messages", message: "Attach a message from the Inbox.", symbol: "text.bubble")
            }
            Text("Task notes").font(.headline)
            ForEach(task.activity.filter { $0.action == "note_added" }) { entry in WorkHistoryRow(entry: entry) }
            TextField("Add a task note…", text: $newNote, axis: .vertical).lineLimit(2...6).taliaCard()
            Button("Add note") {
                Task { if await store.addTaskNote(newNote, to: task) { newNote = "" } }
            }.buttonStyle(TaliaPrimaryButtonStyle())
                .disabled(store.isMutating || newNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newNote.unicodeScalars.count > 1000)
        }
    }

    private func history(_ task: WorkTask) -> some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(task.activity) { WorkHistoryRow(entry: $0) }
            if task.activity.isEmpty {
                WorkEmptyState(title: "No changes recorded", message: "Task updates will appear here.", symbol: "clock")
            }
        }
    }
}

struct WorkHistoryRow: View {
    let entry: WorkActivity
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(Color.taliaLive).padding(.top, 7)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.detail.isEmpty ? entry.action.replacingOccurrences(of: "_", with: " ").capitalized : entry.detail)
                    .font(.subheadline).textSelection(.enabled)
                Text("\(entry.actorName ?? "Talia") · \(entry.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(Color.taliaSecondaryText)
            }
        }
    }
}

private struct EditTaskView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let task: WorkTask
    @State private var assignee = ""
    @State private var project = ""
    @State private var priority: WorkPriority = .medium
    @State private var hasDueDate = false
    @State private var due = Date()
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Assignee", text: $assignee)
                    TextField("Project", text: $project)
                    Picker("Priority", selection: $priority) {
                        ForEach(WorkPriority.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Due date", isOn: $hasDueDate)
                    if hasDueDate { DatePicker("Due", selection: $due) }
                }.listRowBackground(Color.taliaSecondaryBackground)
            }.taliaSurface().navigationTitle("Edit task").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task { await save() } }.disabled(store.isMutating || assignee.count > 120 || project.count > 120)
                    }
                }
                .onAppear {
                    assignee = task.assigneeName ?? ""; project = task.project ?? ""
                    priority = task.priority; hasDueDate = task.dueAt != nil; due = task.dueAt ?? Date()
                }
        }
    }
    private func save() async {
        var fields: [String: WorkValue] = ["priority": .string(priority.rawValue)]
        let name = assignee.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectName = project.trimmingCharacters(in: .whitespacesAndNewlines)
        fields[name.isEmpty ? "clear_assignee" : "assignee_name"] = name.isEmpty ? .bool(true) : .string(name)
        fields[projectName.isEmpty ? "clear_project" : "project"] = projectName.isEmpty ? .bool(true) : .string(projectName)
        fields[hasDueDate ? "due_at" : "clear_due_at"] = hasDueDate ? .string(due.ISO8601Format()) : .bool(true)
        if await store.updateTask(task, fields: fields) { dismiss() }
    }
}

import SwiftUI

struct TasksView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [UUID] = []
    @State private var showFilters = false
    @State private var showClear = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    workspaceTabs
                    switch store.section {
                    case .board: board
                    case .ideas: IdeaBoardsView()
                    case .inbox: TaskInboxView()
                    case .logs: OperationsLogView()
                    case .notes: PersonalNotesView()
                    }
                }
                .padding(20)
            }
            .background(Color.taliaBackground)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await store.refreshCurrentSection() }
            .navigationDestination(for: UUID.self) { TaskDetailView(taskID: $0) }
            .sheet(isPresented: $showFilters) { TaskFiltersView() }
            .confirmationDialog("Clear this column for everyone?", isPresented: $showClear, titleVisibility: .visible) {
                Button("Clear \(store.filters.status.title)", role: .destructive) { Task { await store.clearColumn() } }
            } message: { Text("Tasks will be hidden from the shared board. Their history is retained.") }
            .task(id: store.filters) {
                guard store.section == .board else { return }
                do { try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation() }
                catch { return }
                await store.loadTasks()
            }
            .task(id: store.section) {
                if store.section != .board && store.section != .logs { await store.refreshCurrentSection() }
                if store.section == .board { await store.loadAssignees() }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)); try Task.checkCancellation() }
                    catch { return }
                    if scenePhase == .active && !store.isMutating && path.isEmpty {
                        await store.refreshCurrentSection()
                    }
                }
            }
            .onChange(of: store.requestedTaskID) { _, id in
                if let id { path = [id]; store.requestedTaskID = nil }
            }
            .onChange(of: store.ownerID) { _, _ in path = [] }
        }
        .alert("Workspace", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(store.section == .board ? "Tasks" : store.section.rawValue)
                .font(.largeTitle.bold()).tracking(-0.8)
            if store.section == .notes { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
            Spacer()
            Menu {
                ForEach(WorkspaceStore.Section.allCases) { section in
                    Button(section.rawValue, systemImage: section.symbol) { store.section = section }
                }
            } label: {
                Image(systemName: "square.grid.2x2").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Choose workspace area")
        }
    }

    private var workspaceTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(WorkspaceStore.Section.allCases) { section in
                    Button { store.section = section } label: {
                        Text(section.rawValue).font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .foregroundStyle(store.section == section ? Color.taliaOnAccent : .taliaAccent)
                            .background(store.section == section ? Color.taliaAccent : .taliaSecondaryBackground,
                                        in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(store.section == section ? .isSelected : [])
                }
            }
        }
    }

    private var board: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(store.summary.totalOpen) open · \(store.summary.dueToday) due today")
                .font(.subheadline).foregroundStyle(Color.taliaSecondaryText)
            HStack(spacing: 10) {
                WorkSearchField(text: $store.filters.search, prompt: "Search tasks")
                Button { showFilters = true } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(TaliaIconButtonStyle()).accessibilityLabel("Filter tasks")
            }
            HStack(spacing: 10) {
                Menu {
                    Button("All people") { store.filters.assignee = "" }
                    ForEach(store.assignees, id: \.self) { person in
                        Button(person) { store.filters.assignee = person }
                    }
                } label: {
                    Label(store.filters.assignee.isEmpty ? "All people" : store.filters.assignee, systemImage: "person")
                }.buttonStyle(TaliaSecondaryButtonStyle())
                Button { showFilters = true } label: {
                    Label(store.filters.due.isEmpty ? "Any date" : WorkDueFilter.title(store.filters.due),
                          systemImage: "calendar")
                }.buttonStyle(TaliaSecondaryButtonStyle())
            }
            HStack(spacing: 6) {
                ForEach(WorkStatus.boardColumns) { status in
                    Button { store.filters.status = status } label: {
                        VStack(spacing: 4) {
                            Text(status.title).font(.caption).lineLimit(2).minimumScaleFactor(0.85)
                            Text(count(for: status)).font(.headline)
                        }
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .foregroundStyle(store.filters.status == status ? Color.taliaOnAccent : .taliaAccent)
                        .background(store.filters.status == status ? Color.taliaAccent : .taliaSecondaryBackground,
                                    in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(status.title), \(count(for: status))")
                        .accessibilityAddTraits(store.filters.status == status ? .isSelected : [])
                }
            }
            HStack {
                Text(store.filters.status.title).font(.headline)
                Spacer()
                if [.todo, .done].contains(store.filters.status), !store.tasks.isEmpty {
                    Button("Clear") { showClear = true }.font(.subheadline).disabled(store.isMutating)
                }
            }
            if store.loading.contains("tasks") { ProgressView().frame(maxWidth: .infinity) }
            if store.tasks.isEmpty && !store.loading.contains("tasks") {
                WorkEmptyState(title: "No tasks in this view", message: "Try another status or adjust your filters.", symbol: "checklist")
            }
            LazyVStack(spacing: 12) {
                ForEach(store.tasks) { task in
                    Button { path.append(task.id) } label: { WorkTaskCard(task: task) }.buttonStyle(.plain)
                }
                if store.nextTaskCursor != nil {
                    Button("Load more tasks") { Task { await store.loadTasks(append: true) } }
                        .buttonStyle(TaliaSecondaryButtonStyle()).disabled(store.loading.contains("tasks"))
                }
            }
        }
    }

    private func count(for status: WorkStatus) -> String {
        switch status {
        case .todo: String(store.summary.todo)
        case .inProgress: String(store.summary.inProgress)
        case .blocked: String(store.summary.blocked)
        case .done: "View"
        case .cancelled: ""
        }
    }
}

struct WorkTaskCard: View {
    let task: WorkTask
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(task.publicID).font(.caption).foregroundStyle(Color.taliaSecondaryText)
                Spacer()
                if task.priority == .high || task.priority == .urgent { WorkPriorityLabel(priority: task.priority) }
            }
            HStack {
                Text(task.title).font(.body.weight(.semibold)).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text(task.items.isEmpty ? "\(task.progress)%" : "\(task.completedItems) of \(task.items.count) complete")
                    .font(.caption).foregroundStyle(Color.taliaSecondaryText)
                ProgressView(value: task.progressFraction).tint(Color.taliaAccent)
            }
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle").font(.body)
                Text(task.assigneeName ?? "Unassigned")
                if let date = task.dueAt { Text("·"); Text(date, format: .dateTime.day().month(.abbreviated)) }
            }
            .font(.caption).foregroundStyle(task.isOverdue ? Color.orange : .taliaSecondaryText)
        }.taliaCard()
    }
}

struct WorkPriorityLabel: View {
    let priority: WorkPriority
    var body: some View {
        Label(priority.title, systemImage: "circle.fill")
            .font(.caption).foregroundStyle(priority == .urgent ? Color.red : Color.orange)
    }
}

struct WorkSearchField: View {
    @Binding var text: String
    let prompt: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .accessibilityLabel("Clear search")
            }
        }.padding(.horizontal, 14).frame(minHeight: 46)
            .background(Color.taliaSecondaryBackground, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct WorkEmptyState: View {
    let title: String
    let message: String
    let symbol: String
    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
            .frame(maxWidth: .infinity).padding(.vertical, 16)
    }
}

enum WorkDueFilter {
    static let values = ["", "today", "overdue", "upcoming"]
    static func title(_ value: String) -> String {
        switch value {
        case "today": "Due today"
        case "overdue": "Overdue"
        case "upcoming": "Upcoming"
        default: "Any date"
        }
    }
}

private struct TaskFiltersView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = WorkFilters()
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Assignee", selection: $draft.assignee) {
                        Text("All people").tag("")
                        ForEach(store.assignees, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Priority", selection: $draft.priority) {
                        Text("All priorities").tag("")
                        ForEach(WorkPriority.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("Due", selection: $draft.due) {
                        ForEach(WorkDueFilter.values, id: \.self) { Text(WorkDueFilter.title($0)).tag($0) }
                    }
                    TextField("Project", text: $draft.project)
                }.listRowBackground(Color.taliaSecondaryBackground)
                Section {
                    Button("Reset filters") { var reset = WorkFilters(); reset.status = draft.status; draft = reset }
                }.listRowBackground(Color.taliaSecondaryBackground)
            }
            .taliaSurface().navigationTitle("Filter tasks").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { store.filters = draft; dismiss() }.fontWeight(.semibold)
                }
            }
            .onAppear { draft = store.filters }
        }.presentationDetents([.medium, .large])
    }
}

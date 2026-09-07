import SwiftUI

struct TaskInboxView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var selectedMessage: WorkMessage?
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            Text("Attach each message to a task in the same group.").font(.subheadline).foregroundStyle(Color.taliaSecondaryText)
            if store.loading.contains("inbox") { ProgressView().frame(maxWidth: .infinity) }
            if store.inbox.isEmpty && !store.loading.contains("inbox") {
                WorkEmptyState(title: "Nothing waiting", message: "Messages that need a task will appear here.", symbol: "tray")
            }
            ForEach(store.inbox) { message in
                VStack(alignment: .leading, spacing: 10) {
                    WorkMessageCard(message: message)
                    Button("Choose task & attach") { selectedMessage = message }
                        .buttonStyle(TaliaPrimaryButtonStyle()).disabled(store.isMutating)
                }
            }
            if store.inbox.count >= 200 {
                Text("Showing the latest 200 messages. Attach these and refresh to load the next messages.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $selectedMessage) { message in TaskAttachmentPicker(message: message) }
    }
}

private struct TaskAttachmentPicker: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let message: WorkMessage
    @State private var search = ""
    @State private var results: [WorkTask] = []
    @State private var loading = false
    @State private var error = ""
    var body: some View {
        NavigationStack {
            List {
                Section { Text(message.groupName).foregroundStyle(.secondary) }
                if loading { ProgressView() }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                ForEach(results) { task in
                    Button {
                        Task { if await store.attach(message, to: task) { dismiss() } }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(task.publicID).font(.caption).foregroundStyle(.secondary)
                            Text(task.title).foregroundStyle(Color.taliaAccent)
                        }.padding(.vertical, 8)
                    }.disabled(store.isMutating)
                }
                if !loading && results.isEmpty {
                    Text("No matching task in this group.").foregroundStyle(.secondary)
                }
                if results.count == 50 {
                    Text("Search to narrow these 50 results.").font(.footnote)
                }
            }
            .taliaSurface().navigationTitle("Attach to task").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search tasks in this group")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: search) {
                loading = true
                defer { if !Task.isCancelled { loading = false } }
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    let tasks = try await store.attachmentTargets(for: message, search: search)
                    try Task.checkCancellation()
                    results = tasks
                    error = ""
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription }
                }
            }
        }
    }
}

struct OperationsLogView: View {
    @EnvironmentObject private var store: WorkspaceStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("From your operations groups").font(.subheadline).foregroundStyle(Color.taliaSecondaryText)
            WorkSearchField(text: $store.logSearch, prompt: "Search updates")
            Picker("Severity", selection: $store.logSeverity) {
                Text("All severities").tag("")
                ForEach(["critical", "error", "warning", "notice", "info"], id: \.self) {
                    Text($0.capitalized).tag($0)
                }
            }.pickerStyle(.menu).taliaCard(padding: 8)
            if store.loading.contains("logs") { ProgressView().frame(maxWidth: .infinity) }
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(store.logs) { log in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "circle.fill").font(.system(size: 9)).foregroundStyle(colour(log.severity)).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(log.severity.uppercased()).foregroundStyle(colour(log.severity))
                                Spacer()
                                Text(log.occurredAt, format: .dateTime.day().month().hour().minute()).foregroundStyle(.secondary)
                            }.font(.caption)
                            Text(log.body).font(.body).textSelection(.enabled)
                            Text("\(log.groupName) · \(log.senderName)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if store.nextLogCursor != nil {
                    Button("Load more updates") { Task { await store.loadLogs(append: true) } }
                        .buttonStyle(TaliaSecondaryButtonStyle()).disabled(store.loading.contains("logs"))
                }
            }
            if store.logs.isEmpty && !store.loading.contains("logs") {
                WorkEmptyState(title: "No updates found", message: "Try another severity or search.", symbol: "text.alignleft")
            }
        }
        .task(id: "\(store.logSeverity)|\(store.logSearch)") {
            do { try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation() }
            catch { return }
            await store.loadLogs()
        }
    }
    private func colour(_ severity: String) -> Color {
        switch severity {
        case "critical", "error": .red
        case "warning", "notice": .orange
        default: .taliaSecondaryText
        }
    }
}

struct PersonalNotesView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var bodyText = ""
    @State private var editing: PersonalNote?
    @State private var deleting: PersonalNote?
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            Text("Only visible to you").font(.subheadline).foregroundStyle(Color.taliaSecondaryText)
            HStack {
                TextField(editing == nil ? "Add a personal note…" : "Edit note…", text: $bodyText, axis: .vertical).lineLimit(1...6)
                Button {
                    Task {
                        if await store.saveNote(bodyText, note: editing) { bodyText = ""; editing = nil }
                    }
                } label: { Image(systemName: editing == nil ? "plus.circle.fill" : "checkmark.circle.fill").font(.title).frame(width: 44, height: 44) }
                .disabled(store.isMutating || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bodyText.count > 4000)
                .accessibilityLabel(editing == nil ? "Add note" : "Save note")
            }.taliaCard()
            if editing != nil { Button("Cancel editing") { editing = nil; bodyText = "" }.font(.subheadline) }
            if store.loading.contains("notes") { ProgressView().frame(maxWidth: .infinity) }
            ForEach(store.notes) { note in
                HStack(alignment: .top, spacing: 12) {
                    Button { Task { await store.toggleNote(note) } } label: {
                        Image(systemName: note.doneAt == nil ? "square" : "checkmark.square.fill")
                            .font(.title2).frame(width: 44, height: 44)
                    }.buttonStyle(.plain).disabled(store.isMutating)
                        .accessibilityLabel(note.doneAt == nil ? "Complete note" : "Reopen note")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(note.body).font(.body).strikethrough(note.doneAt != nil)
                            .foregroundStyle(note.doneAt == nil ? Color.taliaAccent : .taliaSecondaryText)
                        Text("\(note.sourceGroupJID == nil ? "Added in app" : "From WhatsApp") · \(note.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Menu {
                        Button("Edit note", systemImage: "pencil") { editing = note; bodyText = note.body }
                        Button("Delete note", systemImage: "trash", role: .destructive) { deleting = note }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    .disabled(store.isMutating)
                }.taliaCard(padding: 12)
            }
            if store.notes.isEmpty && !store.loading.contains("notes") {
                WorkEmptyState(title: "A place for your notes", message: "Add a note here or use a WhatsApp group routed to Personal notes.", symbol: "note.text")
            }
        }
        .confirmationDialog("Delete this private note?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            Button("Delete note", role: .destructive) {
                guard let note = deleting else { return }
                Task { await store.deleteNote(note); deleting = nil }
            }
        }
    }
}


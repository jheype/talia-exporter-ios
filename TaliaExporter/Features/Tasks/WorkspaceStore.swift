import Foundation
import SwiftUI

/// Account-scoped state for work. Network reads are versioned so late responses
/// cannot restore another account's data or overwrite a newer edit.
@MainActor
final class WorkspaceStore: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case board = "Board", ideas = "Ideas", inbox = "Inbox", logs = "Operations log", notes = "My Notes"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .board: "checklist"
            case .ideas: "lightbulb"
            case .inbox: "tray"
            case .logs: "text.alignleft"
            case .notes: "lock"
            }
        }
    }

    @Published var section: Section = .board
    @Published var filters = WorkFilters()
    @Published private(set) var ownerID: UUID?
    @Published private(set) var tasks: [WorkTask] = []
    @Published private(set) var summary: ExporterWidgetSummary = .empty
    @Published private(set) var nextTaskCursor: String?
    @Published private(set) var assignees: [String] = []
    @Published private(set) var detail: WorkTask?
    @Published private(set) var inbox: [WorkMessage] = []
    @Published private(set) var notes: [PersonalNote] = []
    @Published private(set) var logs: [WorkLog] = []
    @Published private(set) var nextLogCursor: String?
    @Published private(set) var boards: [WorkBoard] = []
    @Published private(set) var canvas: WorkCanvas?
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var isMutating = false
    @Published var errorMessage: String?
    @Published var logSeverity = ""
    @Published var logSearch = ""
    @Published var requestedTaskID: UUID?
    @Published var requestedNoteID: UUID?

    let api: WorkspaceAPI?
    var onSessionExpired: ((Error) async -> Void)?
    var onMutation: (() async -> Void)?
    private var generation: UInt64 = 0
    private var reads: [String: UUID] = [:]
    private var mutationID: UUID?
    private var cancelMutation: (() -> Void)?
    private var hasLoadedTasks = false

    init(api: WorkspaceAPI?) { self.api = api }

    func setOwner(_ id: UUID?) {
        guard ownerID != id else { return }
        generation &+= 1
        cancelMutation?()
        cancelMutation = nil
        ownerID = id
        reads = [:]
        loading = []
        mutationID = nil
        isMutating = false
        tasks = []
        summary = .empty
        nextTaskCursor = nil
        assignees = []
        detail = nil
        inbox = []
        notes = []
        logs = []
        nextLogCursor = nil
        boards = []
        canvas = nil
        errorMessage = nil
        filters = WorkFilters()
        section = .board
        requestedTaskID = nil
        requestedNoteID = nil
        logSeverity = ""
        logSearch = ""
        hasLoadedTasks = false
    }

    private struct ReadTicket {
        let channel: String
        let id: UUID
        let generation: UInt64
    }

    private func begin(_ channel: String) -> ReadTicket {
        let ticket = ReadTicket(channel: channel, id: UUID(), generation: generation)
        reads[channel] = ticket.id
        loading.insert(channel)
        return ticket
    }

    private func isCurrent(_ ticket: ReadTicket) -> Bool {
        ownerID != nil && generation == ticket.generation && reads[ticket.channel] == ticket.id && !Task.isCancelled
    }

    private func finish(_ ticket: ReadTicket) {
        if generation == ticket.generation && reads[ticket.channel] == ticket.id {
            loading.remove(ticket.channel)
        }
    }

    private func report(_ error: Error) async {
        guard !Task.isCancelled else { return }
        if let apiError = error as? APIError,
           apiError.statusCode == 401 || apiError.code == "AUTH.REFRESH_FAILED" {
            await onSessionExpired?(error)
        } else if (error as? APIError)?.statusCode == 409 {
            errorMessage = "Someone updated this item. The latest version has been loaded. Review it before trying again."
        } else if (error as? APIError)?.isAmbiguousMutationFailure == true {
            errorMessage = "The change could not be confirmed. Refresh and check the saved state before trying again."
        } else {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Unable to complete the request. Please try again."
        }
    }

    func refreshCurrentSection() async {
        switch section {
        case .board: await loadTasks()
        case .ideas: await loadBoards()
        case .inbox: await loadInbox()
        case .logs: await loadLogs()
        case .notes: await loadNotes()
        }
    }

    func loadTasks(append: Bool = false, onlyIfNeeded: Bool = false) async {
        guard let api, ownerID != nil else { return }
        if onlyIfNeeded && hasLoadedTasks { return }
        if append && (nextTaskCursor == nil || loading.contains("tasks")) { return }
        let query = filters
        let cursor = append ? nextTaskCursor : nil
        let ticket = begin("tasks")
        defer { finish(ticket) }
        do {
            let page = try await api.tasks(query, cursor: cursor)
            guard isCurrent(ticket), query == filters else { return }
            tasks = append ? unique(tasks + page.items) : page.items
            nextTaskCursor = page.nextCursor
            summary = page.summary
            hasLoadedTasks = true
        } catch {
            if isCurrent(ticket) { await report(error) }
        }
    }

    func loadAssignees() async {
        guard let api, ownerID != nil else { return }
        let ticket = begin("assignees")
        defer { finish(ticket) }
        do {
            let result: [String] = try await api.list("exporter/tasks/assignees")
            if isCurrent(ticket) { assignees = result }
        } catch { if isCurrent(ticket) { await report(error) } }
    }

    func openTask(_ id: UUID) async {
        guard let api, ownerID != nil else { return }
        if detail?.id != id { detail = nil }
        let ticket = begin("detail")
        defer { finish(ticket) }
        do {
            let result = try await api.task(id)
            if isCurrent(ticket) { detail = result }
        } catch { if isCurrent(ticket) { await report(error) } }
    }

    func loadInbox() async {
        guard let api, ownerID != nil else { return }
        let ticket = begin("inbox")
        defer { finish(ticket) }
        do {
            let result: [WorkMessage] = try await api.list(
                "exporter/task-messages/unassigned", query: [.init(name: "limit", value: "200")]
            )
            if isCurrent(ticket) { inbox = result }
        } catch { if isCurrent(ticket) { await report(error) } }
    }

    func attachmentTargets(for message: WorkMessage, search: String) async throws -> [WorkTask] {
        guard let api, ownerID != nil else { return [] }
        let scope = generation
        let result: [WorkTask] = try await api.list("exporter/tasks", query: [
            .init(name: "group_jid", value: message.groupJID),
            .init(name: "search", value: search), .init(name: "limit", value: "50"),
            .init(name: "include_done", value: "true")
        ])
        guard scope == generation, !Task.isCancelled else { return [] }
        return result.filter { $0.sourceGroupJID == message.groupJID }
    }

    func loadNotes() async {
        guard let api, ownerID != nil else { return }
        let ticket = begin("notes")
        defer { finish(ticket) }
        do {
            let result: [PersonalNote] = try await api.list("exporter/personal-notes")
            if isCurrent(ticket) { notes = result }
        } catch { if isCurrent(ticket) { await report(error) } }
    }

    func loadNote(_ id: UUID) async -> PersonalNote? {
        guard let api, ownerID != nil else { return nil }
        let ticket = begin("note")
        defer { finish(ticket) }
        do {
            let result = try await api.personalNote(id)
            guard isCurrent(ticket) else { return nil }
            return result
        } catch { if isCurrent(ticket) { await report(error) }; return nil }
    }

    func loadLogs(append: Bool = false) async {
        guard let api, ownerID != nil else { return }
        if append && (nextLogCursor == nil || loading.contains("logs")) { return }
        let severity = logSeverity, search = logSearch
        let ticket = begin("logs")
        defer { finish(ticket) }
        do {
            let page = try await api.logs(severity: severity, search: search, cursor: append ? nextLogCursor : nil)
            guard isCurrent(ticket), severity == logSeverity, search == logSearch else { return }
            logs = append ? unique(logs + page.items) : page.items
            nextLogCursor = page.nextCursor
        } catch { if isCurrent(ticket) { await report(error) } }
    }

    func loadBoards() async {
        guard let api, ownerID != nil else { return }
        let ticket = begin("boards")
        defer { finish(ticket) }
        do {
            let result: [WorkBoard] = try await api.list("exporter/idea-boards")
            if isCurrent(ticket) { boards = result }
        } catch { if isCurrent(ticket) { await report(error) } }
    }

    func loadCanvas(_ id: UUID) async {
        guard let api, ownerID != nil else { return }
        if canvas?.board.id != id { canvas = nil }
        let ticket = begin("canvas")
        defer { finish(ticket) }
        do {
            let result = try await api.canvas(id)
            if isCurrent(ticket) { canvas = result }
        } catch { if isCurrent(ticket) { await report(error) } }
    }

    /// Serialises user mutations, invalidates older reads, and discards results
    /// after sign-out. Non-idempotent POSTs are never automatically replayed.
    @discardableResult
    private func mutate<Result: Sendable>(
        _ operation: @escaping (WorkspaceAPI) async throws -> Result,
        apply: (Result) -> Void
    ) async -> Bool {
        guard let api, ownerID != nil, !isMutating else { return false }
        let scope = generation, id = UUID()
        mutationID = id
        isMutating = true
        errorMessage = nil
        reads.removeAll()
        loading.removeAll()
        defer {
            if scope == generation, mutationID == id {
                mutationID = nil
                cancelMutation = nil
                isMutating = false
            }
        }
        do {
            let work = Task { try await operation(api) }
            cancelMutation = { work.cancel() }
            let value = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            guard scope == generation, ownerID != nil else { return false }
            apply(value)
            Task { [weak self] in
                guard let self, self.generation == scope else { return }
                await self.onMutation?()
            }
            return true
        } catch {
            guard scope == generation, ownerID != nil else { return false }
            if let taskID = detail?.id { await openTask(taskID) }
            guard scope == generation, ownerID != nil else { return false }
            if let boardID = canvas?.board.id { await loadCanvas(boardID) }
            guard scope == generation, ownerID != nil else { return false }
            if section == .notes { await loadNotes() }
            guard scope == generation, ownerID != nil else { return false }
            await report(error)
            return false
        }
    }

    private func applyTask(_ task: WorkTask) {
        if detail?.id == task.id { detail = task }
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            if task.status == filters.status { tasks[index] = task }
            else { tasks.remove(at: index) }
        }
    }

    @discardableResult
    func createTask(fields: [String: WorkValue]) async -> Bool {
        let saved = await mutate({ api in
            try await api.write(.post, path: "exporter/tasks", body: fields, response: WorkTask.self)
        }, apply: { task in
            self.detail = task
            self.requestedTaskID = task.id
        })
        if saved { await loadTasks() }
        return saved
    }

    @discardableResult
    func updateTask(_ task: WorkTask, fields: [String: WorkValue], expectedVersion: Int64? = nil) async -> Bool {
        var body = fields
        body["expected_version"] = .integer(expectedVersion ?? task.version)
        body["reason"] = .string("Updated in Talia Exporter iOS")
        let saved = await mutate({ api in
            try await api.write(.patch, path: "exporter/tasks/\(task.id)", body: body, response: WorkTask.self)
        }, apply: applyTask)
        if saved { await loadTasks() }
        return saved
    }

    func setItem(_ item: WorkItem, on task: WorkTask, done: Bool) async {
        guard !task.status.isClosed else { return }
        let saved = await mutate({ api in
            try await api.write(.patch, path: "exporter/tasks/\(task.id)/items/\(item.id)", body: [
                "expected_version": .integer(item.version), "status": .string(done ? "done" : "todo"),
                "reason": .string("Checklist updated in iOS")
            ], response: WorkTask.self)
        }, apply: applyTask)
        if saved { await loadTasks() }
    }

    @discardableResult
    func addItem(_ body: String, to task: WorkTask) async -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 500, !task.status.isClosed else { return false }
        return await mutate({ api in
            try await api.write(.post, path: "exporter/tasks/\(task.id)/items", body: [
                "expected_task_version": .integer(task.version), "body": .string(text)
            ], response: WorkTask.self)
        }, apply: applyTask)
    }

    func deleteItem(_ item: WorkItem, from task: WorkTask) async {
        _ = await mutate({ api in
            try await api.write(.delete, path: "exporter/tasks/\(task.id)/items/\(item.id)", body: [
                "expected_task_version": .integer(task.version), "expected_item_version": .integer(item.version)
            ], response: WorkTask.self)
        }, apply: applyTask)
    }

    @discardableResult
    func addTaskNote(_ body: String, to task: WorkTask) async -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.count <= 1000, !text.contains("\0") else { return false }
        return await mutate({ api in
            try await api.write(.post, path: "exporter/tasks/\(task.id)/notes", body: [
                "body": .string(text)
            ], response: WorkTask.self)
        }, apply: applyTask)
    }

    @discardableResult
    func deleteTask(_ task: WorkTask) async -> Bool {
        let saved = await mutate({ api in
            try await api.remove("exporter/tasks/\(task.id)", body: ["expected_version": .integer(task.version)])
        }, apply: { _ in self.tasks.removeAll { $0.id == task.id }; self.detail = nil })
        if saved { await loadTasks() }
        return saved
    }

    func clearColumn() async {
        let status = filters.status
        guard status == .todo || status == .done else { return }
        let saved = await mutate({ try await $0.clearColumn(status) }, apply: { _ in })
        if saved { await loadTasks() }
    }

    @discardableResult
    func attach(_ message: WorkMessage, to task: WorkTask) async -> Bool {
        guard message.groupJID == task.sourceGroupJID else { return false }
        return await mutate({ api in
            try await api.write(.post, path: "exporter/task-messages/\(message.id)/attach",
                                body: ["task_id": .string(task.id.uuidString)], response: WorkTask.self)
        }, apply: { result in
            self.inbox.removeAll { $0.id == message.id }
            self.applyTask(result)
        })
    }

    @discardableResult
    func saveNote(_ body: String, note: PersonalNote? = nil, dueAt: Date? = nil) async -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.count <= 4000 else { return false }
        var fields: [String: WorkValue] = ["body": .string(text)]
        if let dueAt { fields["due_at"] = .string(ISO8601DateFormatter().string(from: dueAt)) }
        else if note != nil { fields["due_at"] = .null }
        if let updatedAt = note?.updatedAt { fields["expected_updated_at"] = .string(updatedAt) }
        let payload = fields
        return await mutate({ api in
            try await api.write(note == nil ? .post : .patch,
                                path: note.map { "exporter/personal-notes/\($0.id)" } ?? "exporter/personal-notes",
                                body: payload, response: PersonalNote.self)
        }, apply: { result in
            self.notes.removeAll { $0.id == result.id }
            self.notes.insert(result, at: 0)
        })
    }

    func toggleNote(_ note: PersonalNote) async {
        var fields: [String: WorkValue] = ["done": .bool(note.doneAt == nil)]
        if let updatedAt = note.updatedAt { fields["expected_updated_at"] = .string(updatedAt) }
        let payload = fields
        _ = await mutate({ api in
            try await api.write(.patch, path: "exporter/personal-notes/\(note.id)",
                                body: payload, response: PersonalNote.self)
        }, apply: { result in
            if let index = self.notes.firstIndex(where: { $0.id == result.id }) { self.notes[index] = result }
        })
    }

    func deleteNote(_ note: PersonalNote) async {
        _ = await mutate({ try await $0.remove("exporter/personal-notes/\(note.id)") },
                         apply: { _ in self.notes.removeAll { $0.id == note.id } })
    }

    @discardableResult
    func createBoard(name: String, initialIdeas: [String]) async -> Bool {
        await mutate({ api in
            try await api.write(.post, path: "exporter/idea-boards",
                                body: ["name": .string(name), "initial_ideas": .strings(initialIdeas)],
                                response: WorkBoard.self)
        }, apply: { self.boards.append($0) })
    }

    @discardableResult
    func addIdea(board: WorkBoard, title: String, description: String, colour: String,
                 imageData: [Data], assetOnly: Bool = false) async -> Bool {
        var createdIdea: WorkIdea?
        let scope = generation
        let saved = await mutate({ api in
            try await api.write(.post, path: "exporter/idea-boards/\(board.id)/ideas", body: [
                "title": .string(title), "description": .string(description), "x": .integer(80),
                "y": .integer(80), "border_colour": .string(colour), "asset_only": .bool(assetOnly)
            ], response: WorkIdea.self)
        }, apply: { createdIdea = $0 })
        guard saved, scope == generation, let idea = createdIdea else { return false }
        if !imageData.isEmpty {
            let uploaded = await mutate({ api in
                for data in imageData {
                    try Task.checkCancellation()
                    try await api.uploadImage(data, ideaID: idea.id)
                }
                if assetOnly {
                    let updated = try await api.idea(idea.id)
                    for image in updated.images {
                        let _: WorkNode = try await api.write(.post, path: "exporter/idea-boards/\(board.id)/image-nodes", body: [
                            "image_id": .string(image.id.uuidString), "x": .integer(100), "y": .integer(100),
                            "width": .integer(240), "height": .integer(220), "border_colour": .string(colour)
                        ])
                    }
                }
            }, apply: { _ in })
            if !uploaded, scope == generation {
                errorMessage = assetOnly
                    ? "The image could not be confirmed on the canvas. Refresh the board before adding it again."
                    : "The idea was saved, but an image could not be uploaded. Open the idea to add the image again."
            }
        }
        guard scope == generation else { return false }
        await loadCanvas(board.id)
        await loadBoards()
        return true
    }

    func uploadImages(_ data: [Data], to idea: WorkIdea, boardID: UUID) async {
        let saved = await mutate({ api in
            for image in data { try Task.checkCancellation(); try await api.uploadImage(image, ideaID: idea.id) }
        }, apply: { _ in })
        if saved { await loadCanvas(boardID) }
    }

    @discardableResult
    func editIdea(_ idea: WorkIdea, title: String, description: String, boardID: UUID) async -> Bool {
        let saved = await mutate({ api in
            try await api.write(.patch, path: "exporter/ideas/\(idea.id)", body: [
                "expected_version": .integer(idea.version), "title": .string(title), "description": .string(description)
            ], response: WorkIdea.self)
        }, apply: { _ in })
        if saved { await loadCanvas(boardID) }
        return saved
    }

    func moveNode(_ node: WorkNode, x: Int, y: Int, boardID: UUID) async {
        let saved = await mutate({ api in
            try await api.write(.patch, path: "exporter/idea-nodes/\(node.id)", body: [
                "expected_version": .integer(node.version), "x": .integer(Int64(min(12000, max(0, x)))),
                "y": .integer(Int64(min(12000, max(0, y))))
            ], response: WorkNode.self)
        }, apply: { _ in })
        if saved { await loadCanvas(boardID) }
    }

    func removeNode(_ node: WorkNode, boardID: UUID) async {
        let saved = await mutate({ try await $0.remove("exporter/idea-nodes/\(node.id)") }, apply: { _ in })
        if saved { await loadCanvas(boardID); await loadBoards() }
    }

    @discardableResult
    func configureNode(_ node: WorkNode, colour: String, x: Int, y: Int, width: Int, height: Int, boardID: UUID) async -> Bool {
        let saved = await mutate({ api in
            try await api.write(.patch, path: "exporter/idea-nodes/\(node.id)", body: [
                "expected_version": .integer(node.version), "border_colour": .string(colour),
                "x": .integer(Int64(x)), "y": .integer(Int64(y)),
                "width": .integer(Int64(width)), "height": .integer(Int64(height))
            ], response: WorkNode.self)
        }, apply: { _ in })
        if saved { await loadCanvas(boardID) }
        return saved
    }

    func connect(_ from: WorkNode, _ to: WorkNode, boardID: UUID) async {
        guard from.id != to.id else { return }
        let saved = await mutate({ api in
            try await api.write(.post, path: "exporter/idea-boards/\(boardID)/connections", body: [
                "from_node_id": .string(from.id.uuidString), "to_node_id": .string(to.id.uuidString),
                "colour": .string("#A8A8A8"), "label": .string("")
            ], response: WorkConnection.self)
        }, apply: { _ in })
        if saved { await loadCanvas(boardID) }
    }

    func removeConnection(_ connection: WorkConnection, boardID: UUID) async {
        let saved = await mutate({ try await $0.remove("exporter/idea-connections/\(connection.id)") }, apply: { _ in })
        if saved { await loadCanvas(boardID) }
    }

    func placeImage(_ image: WorkMedia, boardID: UUID) async {
        let saved = await mutate({ api in
            try await api.write(.post, path: "exporter/idea-boards/\(boardID)/image-nodes", body: [
                "image_id": .string(image.id.uuidString), "x": .integer(100), "y": .integer(100),
                "width": .integer(240), "height": .integer(220), "border_colour": .string("#A8A8A8")
            ], response: WorkNode.self)
        }, apply: { _ in })
        if saved { await loadCanvas(boardID) }
    }

    private func unique<Item: Identifiable>(_ values: [Item]) -> [Item] where Item.ID: Hashable {
        var seen = Set<Item.ID>()
        return values.filter { seen.insert($0.id).inserted }
    }
}

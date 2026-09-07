import Foundation

enum WorkStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case todo, inProgress = "in_progress", blocked, done, cancelled
    var id: Self { self }
    static let boardColumns: [Self] = [.todo, .inProgress, .blocked, .done]
    var title: String {
        switch self {
        case .todo: "To do"
        case .inProgress: "In progress"
        case .blocked: "Blocked"
        case .done: "Done"
        case .cancelled: "Cancelled"
        }
    }
    var isClosed: Bool { self == .done || self == .cancelled }
}

enum WorkPriority: String, Codable, CaseIterable, Identifiable, Sendable {
    case low, medium, high, urgent
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

struct WorkTask: Decodable, Identifiable, Sendable {
    let id: UUID
    let publicID: String
    let title: String
    let description: String
    let status: WorkStatus
    let priority: WorkPriority
    let progress: Int
    let assigneeName: String?
    let project: String?
    let dueAt: Date?
    let sourceGroupJID: String
    let sourceGroupName: String
    let sourceSenderName: String
    let version: Int64
    let updatedAt: Date
    private let decodedItems: [WorkItem]?
    private let decodedActivity: [WorkActivity]?
    private let decodedMessages: [WorkMessage]?
    var items: [WorkItem] { decodedItems ?? [] }
    var activity: [WorkActivity] { decodedActivity ?? [] }
    var messages: [WorkMessage] { decodedMessages ?? [] }
    var completedItems: Int { items.filter { $0.status == "done" }.count }
    var progressFraction: Double { Double(min(100, max(0, progress))) / 100 }
    var isOverdue: Bool { !status.isClosed && (dueAt.map { $0 < Date() } ?? false) }

    enum CodingKeys: String, CodingKey {
        case id, title, description, status, priority, progress, project, version
        case publicID = "public_id", assigneeName = "assignee_name", dueAt = "due_at"
        case sourceGroupJID = "source_group_jid", sourceGroupName = "source_group_name"
        case sourceSenderName = "source_sender_name", updatedAt = "updated_at"
        case decodedItems = "items", decodedActivity = "activity", decodedMessages = "messages"
    }
}

struct WorkItem: Decodable, Identifiable, Sendable {
    let id: UUID
    let position: Int
    let body: String
    let status: String
    let version: Int64
}

struct WorkActivity: Decodable, Identifiable, Sendable {
    let id: UUID
    let action: String
    let actorName: String?
    let detail: String
    let createdAt: Date
    enum CodingKeys: String, CodingKey {
        case id, action, detail
        case actorName = "actor_name", createdAt = "created_at"
    }
}

struct WorkMedia: Decodable, Identifiable, Sendable {
    let id: UUID
    let mimeType: String
    let status: String
    enum CodingKeys: String, CodingKey {
        case id, status
        case mimeType = "mime_type"
    }
}

struct WorkMessage: Decodable, Identifiable, Sendable {
    let id: UUID
    let groupJID: String
    let groupName: String
    let senderName: String
    let body: String
    let occurredAt: Date
    private let decodedMedia: [WorkMedia]?
    var media: [WorkMedia] { (decodedMedia ?? []).filter { $0.status == "available" } }
    enum CodingKeys: String, CodingKey {
        case id, body
        case groupJID = "group_jid", groupName = "group_name", senderName = "sender_name"
        case occurredAt = "occurred_at", decodedMedia = "media"
    }
}

struct WorkTaskPage: Decodable, Sendable {
    private let decodedItems: [WorkTask]?
    var items: [WorkTask] { decodedItems ?? [] }
    let nextCursor: String?
    let summary: ExporterWidgetSummary
    enum CodingKeys: String, CodingKey {
        case decodedItems = "items", nextCursor = "next_cursor", summary
    }
}

struct WorkList<Item: Decodable & Sendable>: Decodable, Sendable {
    private let decodedItems: [Item]?
    var items: [Item] { decodedItems ?? [] }
    enum CodingKeys: String, CodingKey { case decodedItems = "items" }
}

struct WorkLog: Codable, Identifiable, Sendable {
    let id: UUID
    let groupName: String
    let senderName: String
    let severity: String
    let body: String
    let occurredAt: Date
    enum CodingKeys: String, CodingKey {
        case id, severity, body
        case groupName = "group_name", senderName = "sender_name", occurredAt = "occurred_at"
    }
}

struct PersonalNote: Decodable, Identifiable, Sendable {
    let id: UUID
    let body: String
    let sourceGroupJID: String?
    let doneAt: Date?
    let createdAt: Date
    enum CodingKeys: String, CodingKey {
        case id, body
        case sourceGroupJID = "source_group_jid", doneAt = "done_at", createdAt = "created_at"
    }
}

struct WorkBoard: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let isGeneral: Bool
    let canvasWidth: Int
    let canvasHeight: Int
    let nodeCount: Int
    enum CodingKeys: String, CodingKey {
        case id, name
        case isGeneral = "is_general", canvasWidth = "canvas_width"
        case canvasHeight = "canvas_height", nodeCount = "node_count"
    }
}

struct WorkIdea: Decodable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let description: String
    let version: Int64
    private let decodedImages: [WorkMedia]?
    var images: [WorkMedia] { (decodedImages ?? []).filter { $0.status == "available" } }
    enum CodingKeys: String, CodingKey {
        case id, title, description, version
        case decodedImages = "images"
    }
}

struct WorkNode: Decodable, Identifiable, Sendable {
    let id: UUID
    let kind: String
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let borderColour: String
    let zIndex: Int
    let version: Int64
    let idea: WorkIdea?
    let image: WorkMedia?
    var title: String { idea?.title ?? "Image" }
    enum CodingKeys: String, CodingKey {
        case id, kind, x, y, width, height, version, idea, image
        case borderColour = "border_colour", zIndex = "z_index"
    }
}

struct WorkConnection: Decodable, Identifiable, Sendable {
    let id: UUID
    let fromNodeID: UUID
    let toNodeID: UUID
    let colour: String
    let label: String
    enum CodingKeys: String, CodingKey {
        case id, colour, label
        case fromNodeID = "from_node_id", toNodeID = "to_node_id"
    }
}

struct WorkCanvas: Decodable, Sendable {
    let board: WorkBoard
    private let decodedNodes: [WorkNode]?
    private let decodedConnections: [WorkConnection]?
    var nodes: [WorkNode] { decodedNodes ?? [] }
    var connections: [WorkConnection] { decodedConnections ?? [] }
    enum CodingKeys: String, CodingKey {
        case board, decodedNodes = "nodes", decodedConnections = "connections"
    }
}

/// Typed JSON values keep mutation payloads Sendable without unsafe Any dictionaries.
enum WorkValue: Encodable, Sendable {
    case string(String), integer(Int64), bool(Bool), strings([String])
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .strings(let value): try container.encode(value)
        }
    }
}

struct WorkFilters: Hashable, Sendable {
    var search = ""
    var assignee = ""
    var priority = ""
    var due = ""
    var project = ""
    var groupJID = ""
    var status: WorkStatus = .inProgress

    func queryItems(cursor: String? = nil) -> [URLQueryItem] {
        var query = [
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "include_done", value: "true"),
            URLQueryItem(name: "status", value: status.rawValue)
        ]
        for (key, value) in [
            ("search", search), ("assignee", assignee), ("priority", priority),
            ("due", due), ("project", project), ("group_jid", groupJID)
        ] where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            query.append(URLQueryItem(name: key, value: value.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return query
    }
}

struct WorkCursorPage<Item: Decodable & Sendable>: Decodable, Sendable {
    private let decodedItems: [Item]?
    var items: [Item] { decodedItems ?? [] }
    let nextCursor: String?
    enum CodingKeys: String, CodingKey {
        case decodedItems = "items", nextCursor = "next_cursor"
    }
}

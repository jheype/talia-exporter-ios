import Foundation

enum WidgetTaskScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case open
    case mine
    case blocked
    case dueToday = "due_today"

    var id: Self { self }

    var title: String {
        switch self {
        case .open: "Open tasks"
        case .mine: "My tasks"
        case .blocked: "Blocked tasks"
        case .dueToday: "Due today"
        }
    }
}

enum WidgetUKChatsPeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case last24Hours = "24h"
    case last7Days = "7d"
    case last30Days = "30d"

    var id: Self { self }

    var title: String {
        switch self {
        case .last24Hours: "Last 24 hours"
        case .last7Days: "Last 7 days"
        case .last30Days: "Last 30 days"
        }
    }
}

struct WidgetPreferences: Codable, Equatable, Sendable {
    var taskScope: WidgetTaskScope = .open
    var assignee = ""
    var project = ""
    var priority = "all"
    var taskGroupJID = ""
    var messageGroupJID = ""
    var includeLogs = true
    var showTaskTitles = true
    var showMessageText = false
    var ukChatsPeriod: WidgetUKChatsPeriod = .last24Hours

    static let `default` = WidgetPreferences()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskScope = try container.decodeIfPresent(WidgetTaskScope.self, forKey: .taskScope) ?? .open
        assignee = try container.decodeIfPresent(String.self, forKey: .assignee) ?? ""
        project = try container.decodeIfPresent(String.self, forKey: .project) ?? ""
        priority = try container.decodeIfPresent(String.self, forKey: .priority) ?? "all"
        taskGroupJID = try container.decodeIfPresent(String.self, forKey: .taskGroupJID) ?? ""
        messageGroupJID = try container.decodeIfPresent(String.self, forKey: .messageGroupJID) ?? ""
        includeLogs = try container.decodeIfPresent(Bool.self, forKey: .includeLogs) ?? true
        showTaskTitles = try container.decodeIfPresent(Bool.self, forKey: .showTaskTitles) ?? true
        showMessageText = try container.decodeIfPresent(Bool.self, forKey: .showMessageText) ?? false
        ukChatsPeriod = try container.decodeIfPresent(
            WidgetUKChatsPeriod.self,
            forKey: .ukChatsPeriod
        ) ?? .last24Hours
    }

    private enum CodingKeys: String, CodingKey {
        case taskScope
        case assignee
        case project
        case priority
        case taskGroupJID
        case messageGroupJID
        case includeLogs
        case showTaskTitles
        case showMessageText
        case ukChatsPeriod
    }

    func normalisedForStorage() -> WidgetPreferences {
        var result = self
        result.assignee = String(
            assignee.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
        )
        result.project = String(
            project.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
        )
        result.taskGroupJID = String(
            taskGroupJID.trimmingCharacters(in: .whitespacesAndNewlines).prefix(255)
        )
        result.messageGroupJID = String(
            messageGroupJID.trimmingCharacters(in: .whitespacesAndNewlines).prefix(255)
        )
        if !["all", "urgent", "high", "medium", "low"].contains(result.priority) {
            result.priority = "all"
        }
        if result.taskScope == .mine && result.assignee.isEmpty {
            result.taskScope = .open
        }
        return result
    }

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        switch taskScope {
        case .open:
            break
        case .mine:
            if !assignee.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items.append(URLQueryItem(name: "assignee", value: assignee))
            }
        case .blocked:
            items.append(URLQueryItem(name: "status", value: "blocked"))
        case .dueToday:
            items.append(URLQueryItem(name: "due", value: "today"))
        }
        if !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(URLQueryItem(name: "project", value: project))
        }
        if priority != "all" {
            items.append(URLQueryItem(name: "priority", value: priority))
        }
        if !taskGroupJID.isEmpty {
            items.append(URLQueryItem(name: "group_jid", value: taskGroupJID))
        }
        if !messageGroupJID.isEmpty {
            items.append(URLQueryItem(name: "message_group_jid", value: messageGroupJID))
        }
        items.append(URLQueryItem(name: "include_logs", value: String(includeLogs)))
        items.append(URLQueryItem(name: "uk_chats_period", value: ukChatsPeriod.rawValue))
        return items
    }
}

struct ExporterWidgetSummary: Codable, Equatable, Sendable {
    let totalOpen: Int64
    let todo: Int64
    let inProgress: Int64
    let blocked: Int64
    let dueToday: Int64
    let overdue: Int64
    let completed7d: Int64
    let completionRate7d: Int

    enum CodingKeys: String, CodingKey {
        case totalOpen = "total_open"
        case todo
        case inProgress = "in_progress"
        case blocked
        case dueToday = "due_today"
        case overdue
        case completed7d = "completed_7d"
        case completionRate7d = "completion_rate_7d"
    }

    static let empty = ExporterWidgetSummary(
        totalOpen: 0,
        todo: 0,
        inProgress: 0,
        blocked: 0,
        dueToday: 0,
        overdue: 0,
        completed7d: 0,
        completionRate7d: 0
    )
}

struct ExporterWidgetTask: Codable, Equatable, Identifiable, Sendable {
    var id: String { publicID }
    let publicID: String
    let title: String
    let status: String
    let priority: String
    let progress: Int
    let assigneeName: String?
    let dueAt: Date?

    enum CodingKeys: String, CodingKey {
        case publicID = "public_id"
        case title
        case status
        case priority
        case progress
        case assigneeName = "assignee_name"
        case dueAt = "due_at"
    }
}

struct ExporterWidgetMessage: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let groupName: String
    let sender: String
    let body: String
    let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case id
        case groupName = "group_name"
        case sender
        case body
        case timestamp
    }
}

struct ExporterWidgetUKChatsCoverage: Codable, Equatable, Sendable {
    let period: WidgetUKChatsPeriod
    let captured: Int64
    let activeGroups: Int
    let discarded: Int64

    enum CodingKeys: String, CodingKey {
        case period
        case captured
        case activeGroups = "active_groups"
        case discarded
    }
}

struct ExporterWidgetSnapshot: Codable, Equatable, Sendable {
    let generatedAt: Date
    let summary: ExporterWidgetSummary
    let tasks: [ExporterWidgetTask]
    let messages: [ExporterWidgetMessage]
    let ukChatsCoverage: ExporterWidgetUKChatsCoverage?

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case summary
        case tasks
        case messages
        case ukChatsCoverage = "uk_chats_coverage"
    }

    static let empty = ExporterWidgetSnapshot(
        generatedAt: .distantPast,
        summary: .empty,
        tasks: [],
        messages: [],
        ukChatsCoverage: nil
    )

    static let preview = ExporterWidgetSnapshot(
        generatedAt: Date(),
        summary: ExporterWidgetSummary(
            totalOpen: 7,
            todo: 2,
            inProgress: 4,
            blocked: 1,
            dueToday: 3,
            overdue: 1,
            completed7d: 9,
            completionRate7d: 74
        ),
        tasks: [
            ExporterWidgetTask(
                publicID: "TAL-1842",
                title: "Fix UK Chats pagination",
                status: "in_progress",
                priority: "high",
                progress: 60,
                assigneeName: "João",
                dueAt: Date().addingTimeInterval(14_400)
            ),
            ExporterWidgetTask(
                publicID: "TAL-1829",
                title: "Watch colour resolver",
                status: "in_progress",
                priority: "medium",
                progress: 30,
                assigneeName: "Seth",
                dueAt: nil
            )
        ],
        messages: [
            ExporterWidgetMessage(
                id: UUID(),
                groupName: "Talia Phase III",
                sender: "João",
                body: "Frontend pagination started",
                timestamp: Date().addingTimeInterval(-420)
            )
        ],
        ukChatsCoverage: ExporterWidgetUKChatsCoverage(
            period: .last24Hours,
            captured: 1_284,
            activeGroups: 18,
            discarded: 47
        )
    )

    func sanitised(using preferences: WidgetPreferences) -> ExporterWidgetSnapshot {
        ExporterWidgetSnapshot(
            generatedAt: generatedAt,
            summary: summary,
            tasks: tasks.map { task in
                ExporterWidgetTask(
                    publicID: task.publicID,
                    title: preferences.showTaskTitles ? task.title : "Task \(task.publicID)",
                    status: task.status,
                    priority: task.priority,
                    progress: task.progress,
                    assigneeName: task.assigneeName,
                    dueAt: task.dueAt
                )
            },
            messages: messages.map { message in
                ExporterWidgetMessage(
                    id: message.id,
                    groupName: message.groupName,
                    sender: message.sender,
                    body: preferences.showMessageText
                        ? message.body
                        : "Open Talia Exporter to view this message.",
                    timestamp: message.timestamp
                )
            },
            ukChatsCoverage: ukChatsCoverage
        )
    }
}

struct ExporterWidgetEnvelope: Codable, Equatable, Sendable {
    let ownerUserID: UUID
    let savedAt: Date
    let snapshot: ExporterWidgetSnapshot
}

enum WidgetSharedStore {
    static let appGroupIdentifier = "group.com.talia.exporter.shared"
    private static let preferencesKey = "talia.exporter.widget-preferences.v1"
    private static let snapshotFilename = "widget-snapshot-v1.json"

    static func loadPreferences() -> WidgetPreferences {
        guard let data = defaults?.data(forKey: preferencesKey),
              let preferences = try? makeDecoder().decode(WidgetPreferences.self, from: data) else {
            return .default
        }
        return preferences.normalisedForStorage()
    }

    static func savePreferences(_ preferences: WidgetPreferences) {
        guard let data = try? makeEncoder().encode(preferences.normalisedForStorage()) else { return }
        defaults?.set(data, forKey: preferencesKey)
    }

    static func resetPreferences() {
        defaults?.removeObject(forKey: preferencesKey)
    }

    static func loadEnvelope() -> ExporterWidgetEnvelope? {
        guard let url = snapshotURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? makeDecoder().decode(ExporterWidgetEnvelope.self, from: data)
    }

    static func save(
        snapshot: ExporterWidgetSnapshot,
        ownerUserID: UUID,
        preferences: WidgetPreferences
    ) throws {
        guard let url = snapshotURL else {
            throw WidgetStoreError.appGroupUnavailable
        }
        let envelope = ExporterWidgetEnvelope(
            ownerUserID: ownerUserID,
            savedAt: Date(),
            snapshot: snapshot.sanitised(using: preferences)
        )
        let data = try makeEncoder().encode(envelope)
        try data.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    static func clearAccountData() {
        if let url = snapshotURL {
            try? FileManager.default.removeItem(at: url)
        }
        resetPreferences()
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    private static var snapshotURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appending(path: snapshotFilename)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private enum WidgetStoreError: Error {
        case appGroupUnavailable
    }
}

import Foundation

enum GroupFunction: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case exporterMentions = "exporter_mentions"
    case tasks
    case logs
    case personalNotes = "personal_notes"

    var id: Self { self }

    var title: String {
        switch self {
        case .exporterMentions: "UK Chats"
        case .tasks: "Task group"
        case .logs: "Log group"
        case .personalNotes: "Personal notes"
        }
    }

    var shortTitle: String {
        switch self {
        case .exporterMentions: "UK Chats"
        case .tasks: "Tasks"
        case .logs: "Logs"
        case .personalNotes: "Personal notes"
        }
    }

    var detail: String {
        switch self {
        case .exporterMentions:
            "Send captured market mentions to UK Chats."
        case .tasks:
            "Create Tasks and Ideas in v14, attach ordinary group messages and track checklist progress."
        case .logs:
            "Keep every text message in the v14 operations log."
        case .personalNotes:
            "Keep notes private to your Talia account."
        }
    }

    var systemImage: String {
        switch self {
        case .exporterMentions: "message.badge.waveform"
        case .tasks: "checklist"
        case .logs: "doc.text.magnifyingglass"
        case .personalNotes: "lock"
        }
    }
}

enum GroupHistorySyncState: String, Codable, Hashable, Sendable {
    case idle
    case queued
    case waitingForAnchor = "waiting_for_anchor"
    case requesting
    case receiving
    case complete
    case stalled
    case availabilityLimited = "availability_limited"
    case failed
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var isActive: Bool {
        switch self {
        case .idle, .queued, .requesting, .receiving:
            true
        case .waitingForAnchor, .complete, .stalled, .availabilityLimited, .failed, .unknown:
            false
        }
    }

    var canRetry: Bool {
        switch self {
        case .waitingForAnchor, .stalled, .availabilityLimited, .failed:
            true
        default:
            false
        }
    }
}

struct ExportGroup: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let participantCount: Int
    var isSelected: Bool
    var function: GroupFunction?
    var functionRevision: Int64?
    var botFeedbackEnabled: Bool?
    var botRemindersEnabled: Bool?
    var botDestinationID: String?
    let lastMessageAt: Date?
    let historySyncState: GroupHistorySyncState?
    let historyTextMessageCount: Int64?
    let historyBatchCount: Int?
    let historyRequestCount: Int?
    let historySyncStartedAt: Date?
    let historySyncUpdatedAt: Date?
    let historySyncCompletedAt: Date?
    let historyOldestMessageAt: Date?
    let historySyncLastError: String?

    enum CodingKeys: String, CodingKey {
        case id = "jid"
        case name
        case participantCount = "participant_count"
        case isSelected = "is_selected"
        case function
        case functionRevision = "function_revision"
        case botFeedbackEnabled = "bot_feedback_enabled"
        case botRemindersEnabled = "bot_reminders_enabled"
        case botDestinationID = "bot_destination_id"
        case lastMessageAt = "last_message_at"
        case historySyncState = "history_sync_state"
        case historyTextMessageCount = "history_text_message_count"
        case historyBatchCount = "history_batch_count"
        case historyRequestCount = "history_request_count"
        case historySyncStartedAt = "history_sync_started_at"
        case historySyncUpdatedAt = "history_sync_updated_at"
        case historySyncCompletedAt = "history_sync_completed_at"
        case historyOldestMessageAt = "history_oldest_message_at"
        case historySyncLastError = "history_sync_last_error"
    }

    init(
        id: String,
        name: String,
        participantCount: Int,
        isSelected: Bool,
        function: GroupFunction? = nil,
        functionRevision: Int64? = nil,
        botFeedbackEnabled: Bool? = nil,
        botRemindersEnabled: Bool? = nil,
        botDestinationID: String? = nil,
        lastMessageAt: Date?,
        historySyncState: GroupHistorySyncState? = nil,
        historyTextMessageCount: Int64? = nil,
        historyBatchCount: Int? = nil,
        historyRequestCount: Int? = nil,
        historySyncStartedAt: Date? = nil,
        historySyncUpdatedAt: Date? = nil,
        historySyncCompletedAt: Date? = nil,
        historyOldestMessageAt: Date? = nil,
        historySyncLastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.participantCount = participantCount
        self.isSelected = isSelected
        self.function = function
        self.functionRevision = functionRevision
        self.botFeedbackEnabled = botFeedbackEnabled
        self.botRemindersEnabled = botRemindersEnabled
        self.botDestinationID = botDestinationID
        self.lastMessageAt = lastMessageAt
        self.historySyncState = historySyncState
        self.historyTextMessageCount = historyTextMessageCount
        self.historyBatchCount = historyBatchCount
        self.historyRequestCount = historyRequestCount
        self.historySyncStartedAt = historySyncStartedAt
        self.historySyncUpdatedAt = historySyncUpdatedAt
        self.historySyncCompletedAt = historySyncCompletedAt
        self.historyOldestMessageAt = historyOldestMessageAt
        self.historySyncLastError = historySyncLastError
    }

    var category: String {
        participantCount == 1 ? "1 participant" : "\(participantCount) participants"
    }

    var initials: String {
        let value = name
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
            .map(String.init)
            .joined()
            .uppercased()
        return value.isEmpty ? "WA" : value
    }

    var lastActivity: String {
        lastMessageAt?.relativeDescription ?? "No recent messages"
    }

    var effectiveHistorySyncState: GroupHistorySyncState {
        historySyncState ?? (isSelected ? .queued : .idle)
    }

    var effectiveFunction: GroupFunction { function ?? .exporterMentions }
    var effectiveFunctionRevision: Int64 { functionRevision ?? 1 }
    var effectiveBotFeedbackEnabled: Bool { botFeedbackEnabled ?? false }
    var effectiveBotRemindersEnabled: Bool { botRemindersEnabled ?? false }

    var capturedTextDescription: String {
        let count = historyTextMessageCount ?? 0
        return "\(count.formatted()) text \(count == 1 ? "message" : "messages")"
    }
}

struct GroupRoutingRequest: Codable, Sendable {
    let groupJID: String
    let function: GroupFunction
    let botFeedbackEnabled: Bool
    let botRemindersEnabled: Bool
    let botDestinationID: String?
    let expectedRevision: Int64

    enum CodingKeys: String, CodingKey {
        case groupJID = "group_jid"
        case function
        case botFeedbackEnabled = "bot_feedback_enabled"
        case botRemindersEnabled = "bot_reminders_enabled"
        case botDestinationID = "bot_destination_id"
        case expectedRevision = "expected_revision"
    }
}

struct GroupRoutingSetting: Codable, Sendable {
    let groupJID: String
    let function: GroupFunction
    let revision: Int64
    let botFeedbackEnabled: Bool
    let botRemindersEnabled: Bool
    let botDestinationID: String?
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case groupJID = "group_jid"
        case function
        case revision
        case botFeedbackEnabled = "bot_feedback_enabled"
        case botRemindersEnabled = "bot_reminders_enabled"
        case botDestinationID = "bot_destination_id"
        case updatedAt = "updated_at"
    }
}

struct GroupSelectionRequest: Codable, Sendable {
    let groupJIDs: [String]

    enum CodingKeys: String, CodingKey {
        case groupJIDs = "group_jids"
    }
}

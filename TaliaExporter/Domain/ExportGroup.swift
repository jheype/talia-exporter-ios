import Foundation

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

    var capturedTextDescription: String {
        let count = historyTextMessageCount ?? 0
        return "\(count.formatted()) text \(count == 1 ? "message" : "messages")"
    }
}

struct GroupSelectionRequest: Codable, Sendable {
    let groupJIDs: [String]

    enum CodingKeys: String, CodingKey {
        case groupJIDs = "group_jids"
    }
}

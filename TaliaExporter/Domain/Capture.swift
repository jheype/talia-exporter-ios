import Foundation

enum CapturedMessageType: String, Codable, Sendable {
    case text
    case image
    case video
    case audio
    case document
    case sticker
    case contact
    case location
    case poll
    case reaction
    case system
    case unknown

    var title: String {
        rawValue.prefix(1).uppercased() + String(rawValue.dropFirst())
    }
}

struct CapturedMediaMetadata: Codable, Hashable, Sendable {
    let mimeType: String?
    let fileName: String?
    let fileSizeBytes: Int64?
    let width: Int?
    let height: Int?
    let durationSeconds: Int?
    let pageCount: Int?
    let isAnimated: Bool?
    let isVoiceMessage: Bool?

    enum CodingKeys: String, CodingKey {
        case mimeType = "mime_type"
        case fileName = "file_name"
        case fileSizeBytes = "file_size_bytes"
        case width
        case height
        case durationSeconds = "duration_seconds"
        case pageCount = "page_count"
        case isAnimated = "is_animated"
        case isVoiceMessage = "is_voice_message"
    }
}

struct CapturedMessage: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let whatsappMessageID: String
    let groupJID: String
    let groupName: String
    let senderJID: String
    let sender: String
    let body: String
    let type: CapturedMessageType
    let timestamp: Date
    let isFromMe: Bool
    let hasMedia: Bool
    let isEdited: Bool
    let isRevoked: Bool
    let revision: Int
    var updatedAt: Date? = nil
    let mediaMetadata: CapturedMediaMetadata?

    enum CodingKeys: String, CodingKey {
        case id
        case whatsappMessageID = "whatsapp_message_id"
        case groupJID = "group_jid"
        case groupName = "group_name"
        case senderJID = "sender_jid"
        case sender
        case body
        case type
        case timestamp
        case isFromMe = "is_from_me"
        case hasMedia = "has_media"
        case isEdited = "is_edited"
        case isRevoked = "is_revoked"
        case revision
        case updatedAt = "updated_at"
        case mediaMetadata = "media_metadata"
    }

    var changeTimestamp: Date {
        updatedAt ?? timestamp
    }

    var isTombstone: Bool {
        isRevoked || type != .text || body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var time: String {
        timestamp.shortTimeDescription
    }

    var containsPrice: Bool {
        guard !isRevoked else { return false }
        return body.range(
            of: #"(?:£|\$|€|HKD|GBP|USD|EUR)\s?\d"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    var displayBody: String {
        if isRevoked { return "Message deleted" }
        if !body.isEmpty { return body }
        if hasMedia { return type.title }
        return type == .system ? "System message" : type.title
    }
}

struct CaptureEvent: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case captured = "Captured"
        case synchronised = "Synchronised"
        case warning = "Needs attention"

        var id: Self { self }
    }

    let id: UUID
    let groupName: String
    let detail: String
    let createdAt: Date
    let kind: Kind

    enum CodingKeys: String, CodingKey {
        case id
        case groupName = "group_name"
        case detail
        case createdAt = "created_at"
        case kind
    }

    var relativeTime: String { createdAt.relativeDescription }
    var time: String { createdAt.shortTimeDescription }
}

struct CursorPage<Value: Codable & Sendable>: Codable, Sendable {
    let items: [Value]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }
}

struct DashboardSnapshot: Codable, Sendable {
    let session: ExporterSession
    let groups: [ExportGroup]
    let events: [CaptureEvent]
    let messages: [CapturedMessage]
}

struct MessageChangeWatermark: Equatable, Sendable {
    let updatedAt: Date
    let id: UUID

    func isAtOrBefore(_ other: MessageChangeWatermark) -> Bool {
        if updatedAt != other.updatedAt { return updatedAt < other.updatedAt }
        return id.uuidString <= other.id.uuidString
    }
}

struct MessageChangeRecord: Sendable {
    let updatedAt: Date
    let revision: Int
    let isTombstone: Bool

    func isOlder(than other: MessageChangeRecord) -> Bool {
        if updatedAt != other.updatedAt { return updatedAt < other.updatedAt }
        return revision < other.revision
    }
}

extension CapturedMessage {
    var changeWatermark: MessageChangeWatermark {
        MessageChangeWatermark(updatedAt: changeTimestamp, id: id)
    }

    var changeRecord: MessageChangeRecord {
        MessageChangeRecord(
            updatedAt: changeTimestamp,
            revision: revision,
            isTombstone: isTombstone
        )
    }
}
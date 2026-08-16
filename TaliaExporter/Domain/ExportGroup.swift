import Foundation

struct ExportGroup: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let participantCount: Int
    var isSelected: Bool
    let lastMessageAt: Date?

    enum CodingKeys: String, CodingKey {
        case id = "jid"
        case name
        case participantCount = "participant_count"
        case isSelected = "is_selected"
        case lastMessageAt = "last_message_at"
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
}

struct GroupSelectionRequest: Codable, Sendable {
    let groupJIDs: [String]

    enum CodingKeys: String, CodingKey {
        case groupJIDs = "group_jids"
    }
}

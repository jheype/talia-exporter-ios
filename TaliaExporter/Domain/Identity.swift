import Foundation

struct TaliaUser: Codable, Equatable, Sendable {
    let id: UUID
    let email: String
    let role: String
    let isOwner: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case role
        case isOwner = "is_owner"
    }

    var displayName: String {
        let localPart = email.split(separator: "@").first.map(String.init) ?? email
        return localPart
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + String($0.dropFirst()) }
            .joined(separator: " ")
    }

    var roleTitle: String {
        isOwner ? "Owner" : "Team member"
    }
}

struct LoginResponse: Codable, Sendable {
    let user: TaliaUser
}

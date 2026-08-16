import Foundation

enum ExporterSessionStatus: String, Codable, Sendable {
    case unlinked
    case pairing
    case connecting
    case connected
    case reconnecting
    case paused
    case interrupted
    case loggedOut = "logged_out"

    var isLinked: Bool {
        switch self {
        case .connected, .reconnecting, .paused, .interrupted:
            true
        case .unlinked, .pairing, .connecting, .loggedOut:
            false
        }
    }

    var title: String {
        switch self {
        case .unlinked: "Not linked"
        case .pairing: "Awaiting link"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .paused: "Paused"
        case .interrupted: "Interrupted"
        case .loggedOut: "Link expired"
        }
    }
}

struct ExporterSession: Codable, Equatable, Sendable {
    let id: UUID
    let userID: UUID
    let phoneNumber: String?
    let status: ExporterSessionStatus
    let captureEnabled: Bool
    let includeMedia: Bool
    let linkedAt: Date?
    let lastConnectedAt: Date?
    let lastMessageAt: Date?
    let lastSynchronisedAt: Date?
    let lastError: String?
    let selectedGroupCount: Int
    let capturedMessageCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case phoneNumber = "phone_number"
        case status
        case captureEnabled = "capture_enabled"
        case includeMedia = "include_media"
        case linkedAt = "linked_at"
        case lastConnectedAt = "last_connected_at"
        case lastMessageAt = "last_message_at"
        case lastSynchronisedAt = "last_synchronised_at"
        case lastError = "last_error"
        case selectedGroupCount = "selected_group_count"
        case capturedMessageCount = "captured_message_count"
    }

    var isLinked: Bool {
        linkedAt != nil && status != .loggedOut && status != .unlinked
    }
}

struct PairingCodeResponse: Codable, Sendable {
    let session: ExporterSession
    let code: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case session
        case code
        case expiresAt = "expires_at"
    }
}

struct CapturePreferences: Codable, Sendable {
    let includeMedia: Bool

    enum CodingKeys: String, CodingKey {
        case includeMedia = "include_media"
    }
}

struct DeviceRegistration: Encodable, Sendable {
    let token: String
    let platform = "ios"
}


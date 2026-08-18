import Foundation

protocol ExporterServing: Sendable {
    func currentUser() async throws -> TaliaUser
    func signIn(email: String, password: String) async throws -> TaliaUser
    func signOut() async throws
    func dashboard() async throws -> DashboardSnapshot
    func session() async throws -> ExporterSession?
    func requestPairingCode(phoneNumber: String) async throws -> PairingCodeResponse
    func groups() async throws -> [ExportGroup]
    func historySyncGroups() async throws -> [ExportGroup]
    func retryHistorySync(groupJIDs: [String]) async throws -> [ExportGroup]
    func saveSelection(groupJIDs: [String]) async throws -> ExporterSession
    func setCaptureEnabled(_ enabled: Bool) async throws -> ExporterSession
    func setPreferences(_ preferences: CapturePreferences) async throws -> ExporterSession
    func unlinkSession() async throws
    func messages(limit: Int) async throws -> [CapturedMessage]
    func events(limit: Int) async throws -> [CaptureEvent]
    func registerDevice(token: String) async throws
    func unregisterDevices() async throws
}

actor ExporterAPI: ExporterServing {
    private struct Credentials: Codable, Sendable {
        let email: String
        let password: String
    }

    private struct PhoneRequest: Codable, Sendable {
        let phoneNumber: String

        enum CodingKeys: String, CodingKey {
            case phoneNumber = "phone_number"
        }
    }

    private struct CaptureRequest: Codable, Sendable {
        let enabled: Bool
    }

    private let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    func currentUser() async throws -> TaliaUser {
        try await client.send(.get, path: "auth/me")
    }

    func signIn(email: String, password: String) async throws -> TaliaUser {
        let response: LoginResponse = try await client.send(
            .post,
            path: "auth/login",
            body: Credentials(email: email, password: password),
            allowsRefresh: false
        )
        return response.user
    }

    func signOut() async throws {
        do {
            try await client.sendWithoutResponse(
                .post,
                path: "auth/logout",
                allowsRefresh: false
            )
        } catch {
            await client.clearAuthenticationCookies()
            throw error
        }
        await client.clearAuthenticationCookies()
    }

    func dashboard() async throws -> DashboardSnapshot {
        try await client.send(.get, path: "exporter/dashboard")
    }

    func session() async throws -> ExporterSession? {
        do {
            return try await client.send(.get, path: "exporter/session")
        } catch let error as APIError where error.statusCode == 404 {
            return nil
        }
    }

    func requestPairingCode(phoneNumber: String) async throws -> PairingCodeResponse {
        try await client.send(
            .post,
            path: "exporter/session/pair",
            body: PhoneRequest(phoneNumber: phoneNumber)
        )
    }

    func groups() async throws -> [ExportGroup] {
        try await client.send(.get, path: "exporter/groups")
    }

    func historySyncGroups() async throws -> [ExportGroup] {
        try await client.send(.get, path: "exporter/groups/history-sync")
    }

    func retryHistorySync(groupJIDs: [String]) async throws -> [ExportGroup] {
        try await client.send(
            .post,
            path: "exporter/groups/history-sync",
            body: GroupSelectionRequest(groupJIDs: groupJIDs)
        )
    }

    func saveSelection(groupJIDs: [String]) async throws -> ExporterSession {
        try await client.send(
            .put,
            path: "exporter/groups/selection",
            body: GroupSelectionRequest(groupJIDs: groupJIDs)
        )
    }

    func setCaptureEnabled(_ enabled: Bool) async throws -> ExporterSession {
        try await client.send(
            .put,
            path: "exporter/session/capture",
            body: CaptureRequest(enabled: enabled)
        )
    }

    func setPreferences(_ preferences: CapturePreferences) async throws -> ExporterSession {
        try await client.send(
            .put,
            path: "exporter/session/preferences",
            body: preferences
        )
    }

    func unlinkSession() async throws {
        try await client.sendWithoutResponse(.delete, path: "exporter/session")
    }

    func messages(limit: Int) async throws -> [CapturedMessage] {
        let page: CursorPage<CapturedMessage> = try await client.send(
            .get,
            path: "exporter/messages",
            queryItems: [URLQueryItem(name: "limit", value: String(limit))]
        )
        return page.items
    }

    func events(limit: Int) async throws -> [CaptureEvent] {
        let page: CursorPage<CaptureEvent> = try await client.send(
            .get,
            path: "exporter/events",
            queryItems: [URLQueryItem(name: "limit", value: String(limit))]
        )
        return page.items
    }

    func registerDevice(token: String) async throws {
        try await client.sendWithoutResponse(
            .post,
            path: "exporter/devices",
            body: DeviceRegistration(token: token)
        )
    }

    func unregisterDevices() async throws {
        try await client.sendWithoutResponse(.delete, path: "exporter/devices")
    }
}

actor PreviewExporterAPI: ExporterServing {
    private var currentSession = PreviewData.session
    private var currentGroups = PreviewData.groups

    func currentUser() async throws -> TaliaUser { PreviewData.user }
    func signIn(email: String, password: String) async throws -> TaliaUser { PreviewData.user }
    func signOut() async throws {}

    func dashboard() async throws -> DashboardSnapshot {
        DashboardSnapshot(
            session: currentSession,
            groups: currentGroups,
            events: PreviewData.events,
            messages: PreviewData.messages
        )
    }

    func session() async throws -> ExporterSession? { currentSession }

    func requestPairingCode(phoneNumber: String) async throws -> PairingCodeResponse {
        PairingCodeResponse(
            session: currentSession,
            code: "84172953",
            expiresAt: Date().addingTimeInterval(280)
        )
    }

    func groups() async throws -> [ExportGroup] { currentGroups }

    func historySyncGroups() async throws -> [ExportGroup] { currentGroups }

    func retryHistorySync(groupJIDs: [String]) async throws -> [ExportGroup] {
        currentGroups = currentGroups.map { group in
            guard groupJIDs.contains(group.id) else { return group }
            return ExportGroup(
                id: group.id,
                name: group.name,
                participantCount: group.participantCount,
                isSelected: group.isSelected,
                lastMessageAt: group.lastMessageAt,
                historySyncState: .queued,
                historyTextMessageCount: group.historyTextMessageCount,
                historyBatchCount: group.historyBatchCount,
                historyRequestCount: group.historyRequestCount,
                historySyncStartedAt: group.historySyncStartedAt,
                historySyncUpdatedAt: Date(),
                historySyncCompletedAt: nil,
                historyOldestMessageAt: group.historyOldestMessageAt,
                historySyncLastError: nil
            )
        }
        return currentGroups
    }

    func saveSelection(groupJIDs: [String]) async throws -> ExporterSession {
        currentGroups = currentGroups.map { group in
            var group = group
            group.isSelected = groupJIDs.contains(group.id)
            return group
        }
        return currentSession
    }

    func setCaptureEnabled(_ enabled: Bool) async throws -> ExporterSession { currentSession }
    func setPreferences(_ preferences: CapturePreferences) async throws -> ExporterSession { currentSession }
    func unlinkSession() async throws {}
    func messages(limit: Int) async throws -> [CapturedMessage] { Array(PreviewData.messages.prefix(limit)) }
    func events(limit: Int) async throws -> [CaptureEvent] { Array(PreviewData.events.prefix(limit)) }
    func registerDevice(token: String) async throws {}
    func unregisterDevices() async throws {}
}

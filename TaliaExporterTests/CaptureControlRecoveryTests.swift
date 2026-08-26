import Foundation
import XCTest
@testable import TaliaExporter

@MainActor
final class CaptureControlRecoveryTests: XCTestCase {
    func testStartTreatsCommittedSelectionAsSuccessAfterConnectionEnds() async {
        let user = Self.user
        let group = Self.group(selected: true)
        let api = CaptureControlAPI(
            user: user,
            session: Self.session(userID: user.id, enabled: false, selectedCount: 0),
            groups: [Self.group(selected: false)],
            selectionMode: .commitThenTransportFailure
        )
        let model = Self.model(api: api, user: user)
        model.route = .connection
        model.connectionStage = .groups
        model.session = Self.session(userID: user.id, enabled: false, selectedCount: 0)
        model.groups = [group]

        await model.completeConnection()

        XCTAssertEqual(model.route, .main)
        XCTAssertEqual(model.selectedTab, .home)
        XCTAssertEqual(model.session?.captureEnabled, true)
        XCTAssertEqual(model.groups.filter(\.isSelected).map(\.id), [group.id])
        XCTAssertNil(model.alert)
    }

    func testResumeReconcilesCommittedServerStateAfterTransportFailure() async {
        let user = Self.user
        let group = Self.group(selected: true)
        let api = CaptureControlAPI(
            user: user,
            session: Self.session(userID: user.id, enabled: false, selectedCount: 1),
            groups: [group],
            captureMode: .commitThenTransportFailure
        )
        let model = Self.model(api: api, user: user)
        model.route = .main
        model.session = Self.session(userID: user.id, enabled: false, selectedCount: 1)
        model.groups = [group]

        await model.setCaptureEnabled(true)

        XCTAssertEqual(model.session?.captureEnabled, true)
        XCTAssertNil(model.alert)
    }

    func testResumeRoutesToGroupsWhenServerHasNoSelection() async {
        let user = Self.user
        let api = CaptureControlAPI(
            user: user,
            session: Self.session(userID: user.id, enabled: false, selectedCount: 0),
            groups: [Self.group(selected: false)],
            captureMode: .noSelectedGroups
        )
        let model = Self.model(api: api, user: user)
        model.route = .main
        model.selectedTab = .settings
        model.session = Self.session(userID: user.id, enabled: false, selectedCount: 0)
        // Deliberately stale local selection: the server is the authority.
        model.groups = [Self.group(selected: true)]

        await model.setCaptureEnabled(true)

        XCTAssertEqual(model.selectedTab, .groups)
        XCTAssertEqual(model.groups.filter(\.isSelected).count, 0)
        XCTAssertEqual(model.alert?.title, "Choose a group first")
        XCTAssertEqual(
            model.alert?.message,
            "Select at least one WhatsApp group, then resume capture."
        )
    }

    func testStartRefreshesGroupsWhenSelectionListIsStale() async {
        let user = Self.user
        let currentGroup = Self.group(
            id: "120363002@g.us",
            name: "Current group",
            selected: false
        )
        let api = CaptureControlAPI(
            user: user,
            session: Self.session(userID: user.id, enabled: false, selectedCount: 0),
            groups: [currentGroup],
            selectionMode: .staleGroups
        )
        let model = Self.model(api: api, user: user)
        model.route = .connection
        model.connectionStage = .groups
        model.session = Self.session(userID: user.id, enabled: false, selectedCount: 0)
        model.groups = [Self.group(selected: true)]

        await model.completeConnection()

        XCTAssertEqual(model.route, .connection)
        XCTAssertEqual(model.connectionStage, .groups)
        XCTAssertEqual(model.groups.map(\.id), [currentGroup.id])
        XCTAssertEqual(model.alert?.title, "Group list changed")
        XCTAssertEqual(
            model.alert?.message,
            "Choose the group again from the refreshed list, then start capture."
        )
    }

    private static let user = TaliaUser(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        email: "lucas.renshaw@icloud.com",
        role: "team_member",
        isOwner: false
    )

    private static func model(api: any ExporterServing, user: TaliaUser) -> AppModel {
        let model = AppModel(dependencies: AppDependencies(
            api: api,
            cache: InMemoryDashboardCache(),
            backgroundRefresh: .shared,
            pushNotifications: PreviewPushNotificationCoordinator()
        ))
        model.user = user
        return model
    }

    private static func group(
        id: String = "120363001@g.us",
        name: String = "Testing ingestion",
        selected: Bool
    ) -> ExportGroup {
        ExportGroup(
            id: id,
            name: name,
            participantCount: 3,
            isSelected: selected,
            lastMessageAt: nil
        )
    }

    private static func session(
        userID: UUID,
        enabled: Bool,
        selectedCount: Int
    ) -> ExporterSession {
        ExporterSession(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            userID: userID,
            phoneNumber: "+44 7700 900123",
            status: enabled ? .connected : .paused,
            captureEnabled: enabled,
            includeMedia: false,
            linkedAt: Date(timeIntervalSince1970: 1_787_680_000),
            lastConnectedAt: Date(timeIntervalSince1970: 1_787_680_000),
            lastMessageAt: nil,
            lastSynchronisedAt: nil,
            lastError: nil,
            selectedGroupCount: selectedCount,
            capturedMessageCount: 0
        )
    }
}

private actor CaptureControlAPI: ExporterServing {
    enum MutationMode: Equatable {
        case succeed
        case commitThenTransportFailure
        case noSelectedGroups
        case staleGroups
    }

    private let authenticatedUser: TaliaUser
    private var storedSession: ExporterSession
    private var storedGroups: [ExportGroup]
    private let selectionMode: MutationMode
    private let captureMode: MutationMode

    init(
        user: TaliaUser,
        session: ExporterSession,
        groups: [ExportGroup],
        selectionMode: MutationMode = .succeed,
        captureMode: MutationMode = .succeed
    ) {
        authenticatedUser = user
        storedSession = session
        storedGroups = groups
        self.selectionMode = selectionMode
        self.captureMode = captureMode
    }

    func currentUser() async throws -> TaliaUser { authenticatedUser }
    func signIn(email: String, password: String) async throws -> TaliaUser { authenticatedUser }
    func signOut() async throws {}
    func clearLocalAuthentication() async {}
    func session() async throws -> ExporterSession? { storedSession }
    func groups() async throws -> [ExportGroup] { storedGroups }
    func events(limit: Int) async throws -> [CaptureEvent] { [] }
    func registerDevice(token: String) async throws {}
    func unregisterDevices() async throws {}
    func unlinkSession() async throws {}

    func dashboard() async throws -> DashboardSnapshot {
        DashboardSnapshot(session: storedSession, groups: storedGroups, events: [], messages: [])
    }

    func requestPairingCode(phoneNumber: String) async throws -> PairingCodeResponse {
        PairingCodeResponse(
            session: storedSession,
            code: "12345678",
            expiresAt: Date().addingTimeInterval(60)
        )
    }

    func retryHistorySync(groupJIDs: [String]) async throws -> [ExportGroup] { storedGroups }

    func saveSelection(groupJIDs: [String]) async throws -> ExporterSession {
        if selectionMode == .staleGroups {
            throw APIError(
                statusCode: 409,
                code: "WHATSAPP.GROUP_SELECTION_STALE",
                message: "The WhatsApp group list changed. Refresh groups and try again."
            )
        }
        storedGroups = storedGroups.map { group in
            var updated = group
            updated.isSelected = groupJIDs.contains(group.id)
            return updated
        }
        storedSession = copySession(enabled: !groupJIDs.isEmpty, selectedCount: groupJIDs.count)
        if selectionMode == .commitThenTransportFailure {
            throw APIError(
                statusCode: nil,
                code: "NETWORK.UNAVAILABLE",
                message: "The connection ended before the response arrived."
            )
        }
        return storedSession
    }

    func setCaptureEnabled(_ enabled: Bool) async throws -> ExporterSession {
        if captureMode == .noSelectedGroups {
            throw APIError(
                statusCode: 409,
                code: "WHATSAPP.NO_SELECTED_GROUPS",
                message: "Select at least one WhatsApp group before resuming capture."
            )
        }
        storedSession = copySession(
            enabled: enabled,
            selectedCount: storedGroups.filter(\.isSelected).count
        )
        if captureMode == .commitThenTransportFailure {
            throw APIError(
                statusCode: nil,
                code: "NETWORK.UNAVAILABLE",
                message: "The connection ended before the response arrived."
            )
        }
        return storedSession
    }

    func setPreferences(_ preferences: CapturePreferences) async throws -> ExporterSession {
        storedSession
    }

    func messagesPage(limit: Int, cursor: String?) async throws -> CursorPage<CapturedMessage> {
        CursorPage(items: [], nextCursor: nil)
    }

    private func copySession(enabled: Bool, selectedCount: Int) -> ExporterSession {
        ExporterSession(
            id: storedSession.id,
            userID: storedSession.userID,
            phoneNumber: storedSession.phoneNumber,
            status: enabled ? .connected : .paused,
            captureEnabled: enabled,
            includeMedia: storedSession.includeMedia,
            linkedAt: storedSession.linkedAt,
            lastConnectedAt: storedSession.lastConnectedAt,
            lastMessageAt: storedSession.lastMessageAt,
            lastSynchronisedAt: storedSession.lastSynchronisedAt,
            lastError: storedSession.lastError,
            selectedGroupCount: selectedCount,
            capturedMessageCount: storedSession.capturedMessageCount
        )
    }
}

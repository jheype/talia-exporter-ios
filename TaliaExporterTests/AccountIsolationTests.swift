import Foundation
import XCTest
@testable import TaliaExporter

@MainActor
final class AccountIsolationTests: XCTestCase {
    func testLegacyWidgetPreferencesKeepExistingChoicesAndDefaultCoveragePeriod() throws {
        let data = Data(#"{"taskScope":"blocked","assignee":"João","project":"UK Chats","priority":"high","taskGroupJID":"tasks@g.us","messageGroupJID":"logs@g.us","includeLogs":false,"showTaskTitles":false,"showMessageText":true}"#.utf8)

        let preferences = try JSONDecoder().decode(WidgetPreferences.self, from: data)

        XCTAssertEqual(preferences.taskScope, .blocked)
        XCTAssertEqual(preferences.project, "UK Chats")
        XCTAssertFalse(preferences.includeLogs)
        XCTAssertFalse(preferences.showTaskTitles)
        XCTAssertTrue(preferences.showMessageText)
        XCTAssertEqual(preferences.ukChatsPeriod, .last24Hours)
    }

    func testLegacyWidgetSnapshotRemainsReadableWithoutCoveragePayload() throws {
        let data = Data(#"{"generated_at":"2026-09-01T12:00:00Z","summary":{"total_open":0,"todo":0,"in_progress":0,"blocked":0,"due_today":0,"overdue":0,"completed_7d":0,"completion_rate_7d":0},"tasks":[],"messages":[]}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snapshot = try decoder.decode(ExporterWidgetSnapshot.self, from: data)

        XCTAssertNil(snapshot.ukChatsCoverage)
    }

    func testWidgetQueryIncludesSelectedUKChatsPeriod() {
        var preferences = WidgetPreferences.default
        preferences.ukChatsPeriod = .last30Days

        let values = Dictionary(
            uniqueKeysWithValues: preferences.queryItems.compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        XCTAssertEqual(values["uk_chats_period"], "30d")
    }

    func testSignInClearsPreviousAccountRuntimeState() async {
        let joao = Self.user("11111111-1111-1111-1111-111111111111", email: "joao@talia.co.uk")
        let lucas = Self.user("22222222-2222-2222-2222-222222222222", email: "lucas@talia.co.uk")
        let api = AccountScopedAPI(user: lucas, session: nil)
        let model = AppModel(dependencies: Self.dependencies(api: api))
        model.user = joao
        model.session = Self.session(owner: joao.id)
        model.groups = [.init(id: "joao-group@g.us", name: "Joao group", participantCount: 3, isSelected: true)]
        model.route = .main

        await model.signIn(email: lucas.email, password: "secret")

        XCTAssertEqual(model.user, lucas)
        XCTAssertNil(model.session)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertEqual(model.route, .connection)
    }

    func testBootstrapRejectsSessionOwnedByAnotherUser() async {
        let lucas = Self.user("22222222-2222-2222-2222-222222222222", email: "lucas@talia.co.uk")
        let joao = Self.user("11111111-1111-1111-1111-111111111111", email: "joao@talia.co.uk")
        let api = AccountScopedAPI(user: lucas, session: Self.session(owner: joao.id))
        let model = AppModel(dependencies: Self.dependencies(api: api))

        await model.bootstrap()

        XCTAssertNil(model.user)
        XCTAssertNil(model.session)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertEqual(model.route, .signedOut)
        XCTAssertEqual(model.alert?.title, "Account data blocked")
        let clearCount = await api.localAuthenticationClearCount()
        XCTAssertEqual(clearCount, 1)
    }

    func testDashboardCacheIsPartitionedByUserID() async {
        let joaoID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let lucasID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let cache = InMemoryDashboardCache()
        let dashboard = CachedDashboard(
            session: Self.session(owner: joaoID),
            groups: [.init(id: "joao-group@g.us", name: "Joao group", participantCount: 3, isSelected: true)],
            events: []
        )

        await cache.save(dashboard, for: joaoID)

        let joaoDashboard = await cache.load(for: joaoID)
        let lucasDashboard = await cache.load(for: lucasID)
        XCTAssertNotNil(joaoDashboard)
        XCTAssertNil(lucasDashboard)
    }

    func testValidOwnedSessionBootstrapsNormally() async {
        let lucas = Self.user("22222222-2222-2222-2222-222222222222", email: "lucas@talia.co.uk")
        let api = AccountScopedAPI(user: lucas, session: Self.session(owner: lucas.id))
        let model = AppModel(dependencies: Self.dependencies(api: api))

        await model.bootstrap()

        XCTAssertEqual(model.user, lucas)
        XCTAssertEqual(model.session?.userID, lucas.id)
        XCTAssertEqual(model.route, .main)
    }

    private static func dependencies(api: any ExporterServing) -> AppDependencies {
        AppDependencies(
            api: api,
            cache: InMemoryDashboardCache(),
            backgroundRefresh: .shared,
            pushNotifications: PreviewPushNotificationCoordinator()
        )
    }

    private static func user(_ id: String, email: String) -> TaliaUser {
        TaliaUser(id: UUID(uuidString: id)!, email: email, role: "team_member", isOwner: false)
    }

    private static func session(owner userID: UUID) -> ExporterSession {
        ExporterSession(
            id: UUID(),
            userID: userID,
            phoneNumber: "+44 7000 000000",
            status: .connected,
            captureEnabled: true,
            includeMedia: false,
            linkedAt: Date(),
            lastConnectedAt: Date(),
            lastMessageAt: nil,
            lastSynchronisedAt: nil,
            lastError: nil,
            selectedGroupCount: 1,
            capturedMessageCount: 0
        )
    }
}

private actor AccountScopedAPI: ExporterServing {
    private let authenticatedUser: TaliaUser
    private let exporterSession: ExporterSession?
    private var clearCount = 0

    init(user: TaliaUser, session: ExporterSession?) {
        authenticatedUser = user
        exporterSession = session
    }

    func localAuthenticationClearCount() -> Int { clearCount }
    func currentUser() async throws -> TaliaUser { authenticatedUser }
    func signIn(email: String, password: String) async throws -> TaliaUser { authenticatedUser }
    func signOut() async throws {}
    func clearLocalAuthentication() async { clearCount += 1 }
    func session() async throws -> ExporterSession? { exporterSession }
    func groups() async throws -> [ExportGroup] { [] }
    func events(limit: Int) async throws -> [CaptureEvent] { [] }
    func registerDevice(token: String) async throws {}
    func unregisterDevices() async throws {}
    func unlinkSession() async throws {}

    func dashboard() async throws -> DashboardSnapshot {
        guard let exporterSession else { throw StubError.noSession }
        return DashboardSnapshot(session: exporterSession, groups: [], events: [], messages: [])
    }

    func requestPairingCode(phoneNumber: String) async throws -> PairingCodeResponse {
        guard let exporterSession else { throw StubError.noSession }
        return PairingCodeResponse(session: exporterSession, code: "12345678", expiresAt: Date().addingTimeInterval(60))
    }

    func retryHistorySync(groupJIDs: [String]) async throws -> [ExportGroup] { [] }

    func saveSelection(groupJIDs: [String]) async throws -> ExporterSession {
        guard let exporterSession else { throw StubError.noSession }
        return exporterSession
    }

    func setCaptureEnabled(_ enabled: Bool) async throws -> ExporterSession {
        guard let exporterSession else { throw StubError.noSession }
        return exporterSession
    }

    func setPreferences(_ preferences: CapturePreferences) async throws -> ExporterSession {
        guard let exporterSession else { throw StubError.noSession }
        return exporterSession
    }

    func messagesPage(limit: Int, cursor: String?) async throws -> CursorPage<CapturedMessage> {
        CursorPage(items: [], nextCursor: nil)
    }

    private enum StubError: Error {
        case noSession
    }
}

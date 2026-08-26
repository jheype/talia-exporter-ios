import Foundation
import XCTest
@testable import TaliaExporter

@MainActor
final class AccountIsolationTests: XCTestCase {
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

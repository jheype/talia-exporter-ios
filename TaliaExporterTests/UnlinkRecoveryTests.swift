import Foundation
import XCTest
@testable import TaliaExporter

@MainActor
final class UnlinkRecoveryTests: XCTestCase {
    func testUnlinkClearsLocalSessionAndCacheAfterSuccess() async {
        let api = UnlinkAPI(user: Self.user, session: Self.session())
        let cache = InMemoryDashboardCache()
        let model = Self.model(api: api, cache: cache)
        await cache.save(CachedDashboard(session: Self.session(), groups: [], events: []), for: Self.user.id)

        await model.unlinkWhatsApp()

        XCTAssertNil(model.session)
        XCTAssertEqual(model.route, .connection)
        XCTAssertEqual(model.connectionStage, .intro)
        XCTAssertEqual(model.user, Self.user)
        XCTAssertNil(model.alert)
        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(model.isUnlinkingWhatsApp)
        let cached = await cache.load(for: Self.user.id)
        XCTAssertNil(cached)
    }

    func testLostDeleteResponseReconcilesWithoutSendingDeleteAgain() async {
        let api = UnlinkAPI(user: Self.user, session: Self.session(), mode: .commitThenTimeout)
        let model = Self.model(api: api)

        await model.unlinkWhatsApp()

        XCTAssertNil(model.session)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.route, .connection)
        let counts = await api.counts()
        XCTAssertEqual(counts.deletes, 1)
        XCTAssertEqual(counts.reads, 1)
    }

    func testAlreadyAbsentDeleteIsConfirmedWithRead() async {
        let api = UnlinkAPI(user: Self.user, session: Self.session(), mode: .missing)
        let model = Self.model(api: api)

        await model.unlinkWhatsApp()

        XCTAssertNil(model.session)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.route, .connection)
        let counts = await api.counts()
        XCTAssertEqual(counts.deletes, 1)
        XCTAssertEqual(counts.reads, 1)
    }

    func testLoggedOutSessionStillPresentIsNotReportedAsUnlinked() async {
        let session = Self.session(status: .loggedOut)
        let api = UnlinkAPI(user: Self.user, session: session, mode: .timeout)
        let model = Self.model(api: api)

        await model.unlinkWhatsApp()

        XCTAssertEqual(model.session, session)
        XCTAssertEqual(model.route, .main)
        XCTAssertEqual(model.alert?.title, "Unable to unlink WhatsApp")
    }

    func testFailedConfirmationDoesNotClearSessionOrPretendSuccess() async {
        let api = UnlinkAPI(
            user: Self.user,
            session: Self.session(),
            mode: .timeout,
            sessionError: Self.timeout
        )
        let model = Self.model(api: api)
        let original = model.session

        await model.unlinkWhatsApp()

        XCTAssertEqual(model.session, original)
        XCTAssertEqual(model.route, .main)
        XCTAssertEqual(model.alert?.title, "Unable to confirm WhatsApp unlink")
    }

    func testForbiddenDeleteDoesNotReconcileOrClearSession() async {
        let api = UnlinkAPI(user: Self.user, session: Self.session(), mode: .forbidden)
        let model = Self.model(api: api)

        await model.unlinkWhatsApp()

        XCTAssertNotNil(model.session)
        XCTAssertEqual(model.alert?.title, "Unable to unlink WhatsApp")
        let counts = await api.counts()
        XCTAssertEqual(counts.deletes, 1)
        XCTAssertEqual(counts.reads, 0)
    }

    func testForeignLocalSessionNeverSendsDelete() async {
        let api = UnlinkAPI(user: Self.user, session: Self.session())
        let model = Self.model(api: api)
        model.session = Self.session(owner: Self.otherUser.id)

        await model.unlinkWhatsApp()

        XCTAssertEqual(model.route, .signedOut)
        XCTAssertEqual(model.alert?.title, "Account data blocked")
        let counts = await api.counts()
        XCTAssertEqual(counts.deletes, 0)
    }

    func testForeignSessionInConfirmationIsRejected() async {
        let api = UnlinkAPI(
            user: Self.user,
            session: Self.session(owner: Self.otherUser.id),
            mode: .timeout
        )
        let model = Self.model(api: api)

        await model.unlinkWhatsApp()

        XCTAssertNil(model.session)
        XCTAssertEqual(model.route, .signedOut)
        XCTAssertEqual(model.alert?.title, "Account data blocked")
    }

    func testBootstrapPreservesOwnedExpiredSessionForExplicitUnlink() async {
        let expired = Self.session(status: .loggedOut)
        let api = UnlinkAPI(user: Self.user, session: expired)
        let model = Self.model(api: api)

        await model.bootstrap()

        XCTAssertEqual(model.session, expired)
        XCTAssertEqual(model.route, .connection)
        XCTAssertNil(model.alert)
        await model.unlinkWhatsApp()
        XCTAssertNil(model.session)
    }

    func testSignInPreservesOwnedExpiredSessionForExplicitUnlink() async {
        let expired = Self.session(status: .loggedOut)
        let api = UnlinkAPI(user: Self.user, session: expired)
        let model = Self.model(api: api)

        await model.signIn(email: Self.user.email, password: "test-password")

        XCTAssertEqual(model.session, expired)
        XCTAssertEqual(model.route, .connection)
        XCTAssertNil(model.alert)
    }

    func testExpiredForeignSessionCannotBeRetainedAtBootstrap() async {
        let api = UnlinkAPI(user: Self.user, session: Self.session(owner: Self.otherUser.id, status: .loggedOut))
        let model = Self.model(api: api)

        await model.bootstrap()

        XCTAssertNil(model.session)
        XCTAssertEqual(model.route, .signedOut)
        XCTAssertEqual(model.alert?.title, "Account data blocked")
    }

    func testUnlinkShowsInFlightStateAndRejectsDoubleTap() async {
        let api = UnlinkAPI(user: Self.user, session: Self.session(), mode: .held)
        let model = Self.model(api: api)
        let unlink = Task { await model.unlinkWhatsApp() }
        await api.waitUntilUnlinkStarted()

        XCTAssertTrue(model.isWorking)
        XCTAssertTrue(model.isUnlinkingWhatsApp)
        await model.checkPairingStatusNow()
        await model.unlinkWhatsApp()
        let counts = await api.counts()
        XCTAssertEqual(counts.deletes, 1)
        XCTAssertEqual(counts.reads, 0)

        await api.finishUnlink()
        await unlink.value
        XCTAssertFalse(model.isUnlinkingWhatsApp)
        XCTAssertNil(model.session)
    }

    func testLateUnlinkResponseDoesNotClearAnotherAccountsSession() async {
        let api = UnlinkAPI(user: Self.user, session: Self.session(), mode: .held)
        let model = Self.model(api: api)
        let unlink = Task { await model.unlinkWhatsApp() }
        await api.waitUntilUnlinkStarted()
        await model.clearAccountOwnedState(for: Self.user.id)
        model.user = Self.otherUser
        let replacement = Self.session(owner: Self.otherUser.id)
        model.session = replacement

        await api.finishUnlink()
        await unlink.value

        XCTAssertEqual(model.session, replacement)
        XCTAssertEqual(model.user, Self.otherUser)
        XCTAssertEqual(model.route, .main)
    }

    func testPairingSessionResponseCannotRestoreSessionAfterUnlink() async {
        let api = UnlinkAPI(user: Self.user, session: Self.session(), heldRead: .session)
        let model = Self.model(api: api)
        model.route = .connection
        model.connectionStage = .pairing
        let check = Task { await model.checkPairingStatusNow() }
        await api.waitUntilReadStarted()

        await model.unlinkWhatsApp()
        await api.finishRead()
        await check.value

        XCTAssertNil(model.session)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertEqual(model.connectionStage, .intro)
        XCTAssertNil(model.alert)
        let counts = await api.counts()
        XCTAssertEqual(counts.groups, 0)
    }

    func testPairingGroupsResponseCannotRestoreSessionAfterUnlink() async {
        let api = UnlinkAPI(user: Self.user, session: Self.session(), heldRead: .groups)
        let model = Self.model(api: api)
        model.route = .connection
        model.connectionStage = .pairing
        let check = Task { await model.checkPairingStatusNow() }
        await api.waitUntilReadStarted()

        await model.unlinkWhatsApp()
        await api.finishRead()
        await check.value

        XCTAssertNil(model.session)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertEqual(model.connectionStage, .intro)
        XCTAssertNil(model.alert)
    }

    func testLatePairingErrorDoesNotReplaceSuccessfulUnlinkWithAnAlert() async {
        let api = UnlinkAPI(user: Self.user, session: Self.session(), sessionError: Self.timeout, heldRead: .session)
        let model = Self.model(api: api)
        model.route = .connection
        model.connectionStage = .pairing
        let check = Task { await model.checkPairingStatusNow() }
        await api.waitUntilReadStarted()

        await model.unlinkWhatsApp()
        await api.finishRead()
        await check.value

        XCTAssertNil(model.session)
        XCTAssertEqual(model.connectionStage, .intro)
        XCTAssertNil(model.alert)
    }

    func testExpiredSessionRestoreCannotOverwriteAccountChangedDuringCacheClear() async throws {
        let api = UnlinkAPI(user: Self.user, session: Self.session())
        let cache = HeldClearCache()
        let model = Self.model(api: api, cache: cache)
        let restore = Task { try await model.restoreConnectionSession(Self.session(status: .loggedOut)) }
        await cache.waitUntilClearStarted()
        model.user = Self.otherUser
        let replacement = Self.session(owner: Self.otherUser.id)
        model.session = replacement

        await cache.finishClear()
        try await restore.value

        XCTAssertEqual(model.user, Self.otherUser)
        XCTAssertEqual(model.session, replacement)
        XCTAssertEqual(model.route, .main)
    }

    private static let user = TaliaUser(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        email: "joao@talia.co.uk", role: "team_member", isOwner: false
    )
    private static let otherUser = TaliaUser(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        email: "other@talia.co.uk", role: "team_member", isOwner: false
    )
    private static let timeout = APIError(statusCode: nil, code: "NETWORK.UNAVAILABLE", message: "The request timed out.")

    private static func model(api: any ExporterServing, cache: any DashboardCaching = InMemoryDashboardCache()) -> AppModel {
        let model = AppModel(dependencies: AppDependencies(
            api: api, cache: cache, backgroundRefresh: .shared,
            pushNotifications: PreviewPushNotificationCoordinator()
        ))
        model.user = user
        model.session = session()
        model.route = .main
        return model
    }

    private static func session(owner: UUID? = nil, status: ExporterSessionStatus = .connected) -> ExporterSession {
        ExporterSession(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            userID: owner ?? user.id, phoneNumber: "+44 7700 900123", status: status,
            captureEnabled: true, includeMedia: false,
            linkedAt: Date(timeIntervalSince1970: 1_787_680_000),
            lastConnectedAt: nil, lastMessageAt: nil, lastSynchronisedAt: nil,
            lastError: nil, selectedGroupCount: 0, capturedMessageCount: 0
        )
    }
}

private actor UnlinkAPI: ExporterServing {
    enum Mode: Equatable { case succeed, commitThenTimeout, timeout, missing, forbidden, held }
    enum ReadPhase: Equatable { case session, groups }
    private let user: TaliaUser
    private var storedSession: ExporterSession?
    private let mode: Mode
    private let sessionError: APIError?
    private var deleteCount = 0
    private var readCount = 0
    private var groupReadCount = 0
    private var unlinkWaiter: CheckedContinuation<Void, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private let heldRead: ReadPhase?
    private var readStarted = false
    private var readWaiter: CheckedContinuation<Void, Never>?
    private var readStartedWaiter: CheckedContinuation<Void, Never>?

    init(user: TaliaUser, session: ExporterSession?, mode: Mode = .succeed, sessionError: APIError? = nil, heldRead: ReadPhase? = nil) {
        self.user = user
        self.storedSession = session
        self.mode = mode
        self.sessionError = sessionError
        self.heldRead = heldRead
    }

    func counts() -> (deletes: Int, reads: Int, groups: Int) { (deleteCount, readCount, groupReadCount) }
    func waitUntilReadStarted() async {
        if readStarted { return }
        await withCheckedContinuation { readStartedWaiter = $0 }
    }
    func finishRead() { readWaiter?.resume(); readWaiter = nil }
    private func holdRead(_ phase: ReadPhase) async {
        guard heldRead == phase else { return }
        readStarted = true
        await withCheckedContinuation { continuation in
            readWaiter = continuation
            readStartedWaiter?.resume()
            readStartedWaiter = nil
        }
    }
    func waitUntilUnlinkStarted() async {
        if deleteCount > 0 { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func finishUnlink() { unlinkWaiter?.resume(); unlinkWaiter = nil }
    func unlinkSession() async throws {
        deleteCount += 1
        if mode == .held {
            await withCheckedContinuation { continuation in
                unlinkWaiter = continuation
                startedWaiter?.resume()
                startedWaiter = nil
            }
        }
        if mode == .succeed || mode == .held || mode == .commitThenTimeout || mode == .missing {
            storedSession = nil
        }
        switch mode {
        case .commitThenTimeout, .timeout:
            throw APIError(statusCode: nil, code: "NETWORK.UNAVAILABLE", message: "The request timed out.")
        case .missing:
            throw APIError(statusCode: 404, code: "EXPORTER.NOT_FOUND", message: "Session not found.")
        case .forbidden:
            throw APIError(statusCode: 403, code: "EXPORTER.FORBIDDEN", message: "Forbidden.")
        case .succeed, .held: break
        }
    }
    func session() async throws -> ExporterSession? {
        readCount += 1
        let response = storedSession
        await holdRead(.session)
        if let sessionError { throw sessionError }
        return response
    }
    func currentUser() async throws -> TaliaUser { user }
    func signIn(email: String, password: String) async throws -> TaliaUser { user }
    func signOut() async throws {}
    func clearLocalAuthentication() async {}
    func groups() async throws -> [ExportGroup] {
        groupReadCount += 1
        await holdRead(.groups)
        return [ExportGroup(id: "previous-phone@g.us", name: "Previous phone group", participantCount: 3, isSelected: true, lastMessageAt: nil)]
    }
    func retryHistorySync(groupJIDs: [String]) async throws -> [ExportGroup] { [] }
    func events(limit: Int) async throws -> [CaptureEvent] { [] }
    func registerDevice(token: String) async throws {}
    func unregisterDevices() async throws {}
    func messagesPage(limit: Int, cursor: String?) async throws -> CursorPage<CapturedMessage> { CursorPage(items: [], nextCursor: nil) }
    func dashboard() async throws -> DashboardSnapshot {
        DashboardSnapshot(session: try requireSession(), groups: [], events: [], messages: [])
    }
    func requestPairingCode(phoneNumber: String) async throws -> PairingCodeResponse {
        PairingCodeResponse(session: try requireSession(), code: "12345678", expiresAt: Date().addingTimeInterval(60))
    }
    func saveSelection(groupJIDs: [String], startCapture: Bool) async throws -> ExporterSession { try requireSession() }
    func setCaptureEnabled(_ enabled: Bool) async throws -> ExporterSession { try requireSession() }
    func setPreferences(_ preferences: CapturePreferences) async throws -> ExporterSession { try requireSession() }
    private func requireSession() throws -> ExporterSession {
        guard let storedSession else { throw APIError(statusCode: 404, code: "EXPORTER.NOT_FOUND", message: "No session.") }
        return storedSession
    }
}

private actor HeldClearCache: DashboardCaching {
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var clearWaiter: CheckedContinuation<Void, Never>?

    func load(for userID: UUID) async -> CachedDashboard? { nil }
    func save(_ dashboard: CachedDashboard, for userID: UUID) async {}
    func clear(for userID: UUID) async {
        started = true
        await withCheckedContinuation { continuation in
            clearWaiter = continuation
            startedWaiter?.resume()
            startedWaiter = nil
        }
    }
    func waitUntilClearStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func finishClear() { clearWaiter?.resume(); clearWaiter = nil }
}

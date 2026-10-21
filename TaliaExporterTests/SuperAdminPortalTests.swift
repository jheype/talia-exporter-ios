import Foundation
import SwiftUI
import XCTest
@testable import TaliaExporter

@MainActor
final class SuperAdminPortalTests: XCTestCase {
    func testExporterOwnerDoesNotGrantSuperAdminAccess() {
        let model = AppModel.preview()
        XCTAssertEqual(model.superAdmin.phase, .signedOut)
        XCTAssertNil(model.superAdmin.api?.credentials)
        XCTAssertEqual(SuperAdminSection.allCases.count, 13)
    }
    func testAccountSwitchDiscardsCredentialsAndPendingAlert() throws {
        let store = SuperAdminPortalStore(), owner = UUID()
        store.setOwner(owner)
        let retired = try XCTUnwrap(store.api)
        store.openAlert(UUID().uuidString)
        store.setOwner(UUID())
        XCTAssertNil(retired.credentials)
        XCTAssertNil(store.alertToOpen)
        XCTAssertEqual(store.phase, .signedOut)
        XCTAssertFalse(store.api === retired)
        store.setOwner(nil)
    }
    func testPushRouteRejectsForeignPayloadsAndMalformedIDs() {
        let router = SANotificationRouter.shared
        router.pendingAlertID = nil
        router.receive(["kind": "other", "alert_id": UUID().uuidString])
        XCTAssertNil(router.pendingAlertID)
        router.receive(["kind": "sa-security", "alert_id": "https://evil.test"])
        XCTAssertNil(router.pendingAlertID)
        let id = UUID().uuidString
        router.receive(["kind": "sa-security", "alert_id": id])
        XCTAssertEqual(router.pendingAlertID, id)
        router.pendingAlertID = nil
        let digest = UUID().uuidString
        router.receive(["kind": "sa-inactivity", "alert_id": digest])
        XCTAssertEqual(router.pendingAlertID, digest)
        router.pendingAlertID = nil
    }
    func testUserAnalyticsFiltersMatchServerAndFormatting() {
        XCTAssertEqual(SAUserFilter.allCases.map(\.rawValue), ["all", "at_risk", "inactive", "warm", "follow_up_due", "not_contacted", "internal"])
        XCTAssertEqual(SAUserStage.allCases.map(\.rawValue), ["champion", "warm", "neutral", "cold", "do_not_contact"])
        XCTAssertEqual(saDuration(0), "0m")
        XCTAssertEqual(saDuration(30), "under 1m")
        XCTAssertEqual(saDuration(45 * 60), "45m")
        XCTAssertEqual(saDuration(80 * 60), "1h 20m")
        XCTAssertEqual(saDuration(7200), "2h")
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 23, minute: 30))!
        XCTAssertEqual(saDayString(day), "2026-03-29")
        XCTAssertEqual(saDayString(saDayDate("2026-10-27")!), "2026-10-27")
        XCTAssertNil(saDayDate("27/10/2026"))
        XCTAssertNotNil(saDate("2026-10-20T09:00:00.123Z"))
        XCTAssertNotNil(saDate("2026-10-20T09:00:00Z"))
    }
    func testAccountViewsStagesAndFollowUpsMatchServer() {
        XCTAssertEqual(SAAccountView.allCases.map(\.rawValue), ["follow_up", "upcoming", "prospects", "onboarding", "customers", "closed", "all", "internal"])
        XCTAssertEqual(saAccountStages.map(\.0), ["lead", "contacted", "demo", "invited", "onboarding", "customer", "at_risk", "churned", "lost"])
        XCTAssertEqual(saAccountWarmth.map(\.0), ["champion", "warm", "neutral", "cold", "do_not_contact"])
        let today = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 10))!
        XCTAssertNil(saFollowUpValue(.keep, picked: today, today: today))
        XCTAssertEqual(saFollowUpValue(.none, picked: today, today: today), .null)
        XCTAssertEqual(saFollowUpValue(.week, picked: today, today: today), .string("2026-10-28"))
        XCTAssertEqual(saFollowUpValue(.month, picked: today, today: today), .string("2026-11-20"))
        // Keep is offered only for a follow-up still to come (a due one is done once they are reached).
        XCTAssertFalse(saFollowUpChoices(current: "2026-10-21", isNote: false, today: today).contains(.keep))
        XCTAssertTrue(saFollowUpChoices(current: "2026-10-25", isNote: false, today: today).contains(.keep))
        // No answer keeps a due follow-up due, or tries again tomorrow.
        XCTAssertTrue(saFollowUpChoices(current: "2026-10-21", isNote: false, noAnswer: true, today: today).contains(.keep))
        XCTAssertEqual(saDefaultFollowUp(current: "2026-10-21", isNote: false, outcome: "no_answer", today: today), .keep)
        XCTAssertEqual(saDefaultFollowUp(current: "", isNote: false, outcome: "no_answer", today: today), .tomorrow)
        XCTAssertEqual(saDefaultFollowUp(current: "2026-10-21", isNote: false, outcome: "reached", today: today), .week)
        XCTAssertEqual(SAFollowUpChoice.keep.title(keeping: today, due: true), "Keep it due")
        XCTAssertEqual(saTimeString(Calendar.current.date(bySettingHour: 9, minute: 5, second: 0, of: today)!), "09:05")
        XCTAssertEqual(saTimeString(saTimeDate("14:30", on: today)!), "14:30")
        XCTAssertNil(saTimeDate("soon"))
        let booked: SAValue = .object(["reasons": .array([]), "follow_up_at": .string("2026-10-23"), "follow_up_time": .string("14:30"), "next_step": .string("Call Jo")])
        XCTAssertTrue(saAccountNextLine(booked).text.hasSuffix(" at 14:30 · Call Jo"))
        XCTAssertFalse(saAccountNextLine(booked).due)
        let due: SAValue = .object(["reasons": .array([.object(["label": .string("Trial ends in 3 days")]), .object(["label": .string("Payment failed")])])])
        XCTAssertEqual(saAccountNextLine(due).text, "Trial ends in 3 days · Payment failed")
        XCTAssertTrue(saAccountNextLine(due).due)
        XCTAssertEqual(saAccountNextLine(.object([:])).text, "No follow-up")
    }
    func testNativeRequestUsesVersionedCRMAPIAndNoExporterCookies() async throws {
        let recorder = SARequestRecorder()
        SAStubProtocol.install { request in
            recorder.add(request)
            return (200, #"{"authorised":true}"#)
        }
        defer { SAStubProtocol.install(nil) }
        let client = makeClient()
        defer { client.clear() }
        try client.save(.init(accessToken: "crm-token", refreshToken: "crm-refresh", userID: UUID().uuidString, email: "sa@example.test"))
        _ = try await client.request("admin/session")
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://app.taliaai.com/api/v1/admin/session")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer crm-token")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }
    func testRefreshRotatesPairAndRetriesUnauthorisedRead() async throws {
        let recorder = SARequestRecorder()
        SAStubProtocol.install { request in
            recorder.add(request)
            if request.url!.path.hasSuffix("auth/refresh") { return (200, #"{"accessToken":"new-access","refreshToken":"new-refresh"}"#) }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer new-access" { return (200, #"{"authorised":true}"#) }
            return (401, #"{"code":"AUTH.EXPIRED","message":"Expired"}"#)
        }
        defer { SAStubProtocol.install(nil) }
        let client = makeClient(); defer { client.clear() }
        try client.save(.init(accessToken: "old", refreshToken: "refresh", userID: UUID().uuidString, email: "sa@example.test"))
        _ = try await client.request("admin/session")
        XCTAssertEqual(client.credentials?.refreshToken, "new-refresh")
        XCTAssertEqual(recorder.requests.count, 3)
    }
    func testAmbiguousMutationIsNeverRetriedAutomatically() async throws {
        let recorder = SARequestRecorder()
        SAStubProtocol.install { request in recorder.add(request); return (503, #"{"message":"Unavailable"}"#) }
        defer { SAStubProtocol.install(nil) }
        let client = makeClient(); defer { client.clear() }
        try client.save(.init(accessToken: "access", refreshToken: "refresh", userID: UUID().uuidString, email: "sa@example.test"))
        do { _ = try await client.request("admin/tenants", method: "POST", body: [:], requestID: "same-request"); XCTFail("Expected failure") }
        catch { XCTAssertEqual((error as? SARequestError)?.status, 503) }
        XCTAssertEqual(recorder.requests.count, 1)
    }
    func testForeignAPIPathsAreRejectedBeforeSendingCredentials() async throws {
        let client = makeClient(); defer { client.clear() }
        for path in ["https://evil.test/", "/auth/login", "../admin/session"] {
            do { _ = try await client.request(path); XCTFail("Should reject \(path)") } catch { XCTAssertTrue(error is URLError) }
        }
    }
    func testNativeSignInRendersInBothAppearances() throws {
        let store = SuperAdminPortalStore()
        for appearance in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: SuperAdminPortalView(store: store)
                .environment(\.colorScheme, appearance).frame(width: 393, height: 852))
            XCTAssertNotNil(renderer.uiImage)
        }
    }
    private func makeClient() -> SuperAdminAPI {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.protocolClasses = [SAStubProtocol.self]
        return SuperAdminAPI(owner: UUID(), session: URLSession(configuration: config), restore: false)
    }
}
private final class SARequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [URLRequest] = []
    func add(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; saved.append(request) }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return saved }
}
private final class SAStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> (Int, String))?
    static func install(_ value: ((URLRequest) -> (Int, String))?) { lock.lock(); defer { lock.unlock() }; handler = value }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        let (status, body) = handler?(request) ?? (500, "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

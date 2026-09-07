import XCTest
import SwiftUI
@testable import TaliaExporter

final class WorkspaceContractTests: XCTestCase {
    override func tearDown() {
        WorkspaceStubProtocol.install(nil)
        super.tearDown()
    }

    func testNullCollectionsAndFractionalDatesDecode() async throws {
        WorkspaceStubProtocol.install { _ in (200, Self.page, 0) }
        let page = try await makeAPI().tasks(WorkFilters())
        XCTAssertEqual(page.items.count, 1)
        XCTAssertTrue(page.items[0].items.isEmpty)
        XCTAssertTrue(page.items[0].activity.isEmpty)
        XCTAssertTrue(page.items[0].messages.isEmpty)
        XCTAssertEqual(page.items[0].version, 11)
        XCTAssertEqual(page.nextCursor, "page-2")
    }

    func testFiltersAreEscapedAndCursorIsPreserved() async throws {
        let observed = RequestRecorder()
        WorkspaceStubProtocol.install { request in
            observed.append(request)
            return (200, Self.page, 0)
        }
        var filters = WorkFilters()
        filters.search = "Pricing & stock"
        filters.groupJID = "123@g.us"
        filters.assignee = "A B"
        _ = try await makeAPI().tasks(filters, cursor: "a+b/c=")
        let items = URLComponents(url: try XCTUnwrap(observed.values.first?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first { $0.name == "search" }?.value, "Pricing & stock")
        XCTAssertEqual(items?.first { $0.name == "cursor" }?.value, "a+b/c=")
        XCTAssertEqual(items?.first { $0.name == "status" }?.value, "in_progress")
    }

    @MainActor
    func testAccountChangeDiscardsLateTaskResponse() async throws {
        let requested = expectation(description: "Request started")
        WorkspaceStubProtocol.install { _ in
            requested.fulfill()
            return (200, Self.page, 0.15)
        }
        let store = WorkspaceStore(api: makeAPI())
        store.setOwner(UUID())
        let loading = Task { await store.loadTasks() }
        await fulfillment(of: [requested], timeout: 2)
        let nextOwner = UUID()
        store.setOwner(nextOwner)
        await loading.value
        XCTAssertEqual(store.ownerID, nextOwner)
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertEqual(store.summary, .empty)
        XCTAssertNil(store.nextTaskCursor)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testConflictingEditUsesVersionAndIsNotReplayed() async throws {
        let requests = RequestRecorder()
        WorkspaceStubProtocol.install { request in
            requests.append(request)
            if request.httpMethod == "PATCH" {
                return (409, #"{"code":"EXPORTER.CONFLICT","message":"Version changed"}"#, 0)
            }
            return (200, Self.task, 0)
        }
        let store = WorkspaceStore(api: makeAPI())
        store.setOwner(UUID())
        await store.openTask(Self.taskID)
        let task = try XCTUnwrap(store.detail)
        let saved = await store.updateTask(task, fields: ["status": .string("done")])
        XCTAssertFalse(saved)
        let writes = requests.values.filter { $0.httpMethod == "PATCH" }
        XCTAssertEqual(writes.count, 1)
        let data = try XCTUnwrap(writes.first).bodyData
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["expected_version"] as? Int, 11)
        XCTAssertEqual(body["status"] as? String, "done")
        XCTAssertEqual(store.detail?.status, .inProgress)
        XCTAssertTrue(store.errorMessage?.contains("Someone updated") == true)
    }

    @MainActor
    func testAccountResetClearsPrivateDraftStateAndLoadedNotes() async throws {
        WorkspaceStubProtocol.install { _ in
            (200, #"{"items":[{"id":"33333333-3333-3333-3333-333333333333","body":"Private note","created_at":"2026-09-07T10:00:00Z"}]}"#, 0)
        }
        let store = WorkspaceStore(api: makeAPI())
        store.setOwner(UUID())
        await store.loadNotes()
        XCTAssertEqual(store.notes.count, 1)
        store.section = .notes
        store.filters.search = "private"
        store.errorMessage = "old account error"
        store.setOwner(nil)
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertEqual(store.filters.search, "")
        XCTAssertEqual(store.section, .board)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isMutating)
    }

    func testWidgetPrivacyRemovesBodiesAndTitles() {
        var preferences = WidgetPreferences()
        preferences.showTaskTitles = false
        preferences.showMessageText = false
        let original = ExporterWidgetSnapshot.preview
        let safe = original.sanitised(using: preferences)
        XCTAssertFalse(safe.tasks.contains { $0.title == original.tasks[0].title })
        XCTAssertFalse(safe.messages.contains { $0.body == original.messages[0].body })
        XCTAssertEqual(safe.summary, original.summary)
    }

    func testPersonalNotesRoutingDecodes() throws {
        XCTAssertEqual(try JSONDecoder().decode(GroupFunction.self, from: Data(#""personal_notes""#.utf8)), .personalNotes)
    }

    func testCreationSendsUKCalendarDateAndDoesNotReplayUnavailableWrite() async throws {
        let observed = RequestRecorder()
        WorkspaceStubProtocol.install { request in
            observed.append(request)
            return (503, #"{"code":"SERVICE.UNAVAILABLE","message":"Unavailable"}"#, 0)
        }
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-07T23:30:00Z"))
        do {
            let _: WorkTask = try await makeAPI().write(.post, path: "exporter/tasks", body: [
                "group_jid": .string("123@g.us"), "title": .string("Check stock"),
                "due": .string(WorkDueFilter.creationDate(date))
            ])
            XCTFail("An unavailable response must be surfaced")
        } catch let error as APIError { XCTAssertEqual(error.statusCode, 503) }
        XCTAssertEqual(observed.values.count, 1)
        let request = try XCTUnwrap(observed.values.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.bodyData) as? [String: Any])
        XCTAssertEqual(body["due"] as? String, "2026-09-08")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    private func makeAPI() -> WorkspaceAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkspaceStubProtocol.self]
        config.httpCookieStorage = nil
        return WorkspaceAPI(client: APIClient(baseURL: URL(string: "https://workspace.test/api/v1/")!,
                                             session: URLSession(configuration: config)))
    }

    static let taskID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let task = """
    {"id":"22222222-2222-2222-2222-222222222222","public_id":"TAL-47","title":"Review pricing evidence","description":"Review the latest information from the team.","status":"in_progress","priority":"high","progress":60,"assignee_name":"Jamie","source_group_jid":"123@g.us","source_group_name":"Talia Tasks","source_sender_name":"Alex","version":11,"updated_at":"2026-09-07T10:00:00.123Z","items":null,"activity":null,"messages":null}
    """
    static let page = """
    {"items":[\(task)],"next_cursor":"page-2","summary":{"total_open":9,"todo":3,"in_progress":5,"blocked":1,"due_today":2,"overdue":1,"completed_7d":4,"completion_rate_7d":40}}
    """
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; requests.append(request) }
    var values: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

private final class WorkspaceStubProtocol: URLProtocol {
    typealias Handler = (URLRequest) -> (Int, String, TimeInterval)
    private static let lock = NSLock()
    private static var handler: Handler?
    static func install(_ value: Handler?) { lock.lock(); defer { lock.unlock() }; handler = value }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        let (status, body, delay) = handler?(request) ?? (404, "{}", 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private extension URLRequest {
    var bodyData: Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}


@MainActor
final class ApprovedLayoutTests: XCTestCase {
    func testFiveTabsRenderInLightAndDarkWithoutNetwork() async throws {
        var dependencies = AppDependencies.preview
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkspaceStubProtocol.self]
        config.httpCookieStorage = nil
        dependencies.workspaceAPI = WorkspaceAPI(client: APIClient(
            baseURL: URL(string: "https://layout.test/api/v1/")!, session: URLSession(configuration: config)))
        WorkspaceStubProtocol.install { request in
            if request.url?.path.hasSuffix("assignees") == true { return (200, #"{"items":["Jamie"]}"#, 0) }
            return (200, WorkspaceContractTests.page, 0)
        }
        defer { WorkspaceStubProtocol.install(nil) }
        let model = AppModel(dependencies: dependencies)
        model.user = PreviewData.user
        model.session = PreviewData.session
        model.groups = PreviewData.groups
        model.messages = PreviewData.messages
        model.events = PreviewData.events
        model.widgetSnapshot = .preview
        model.route = .main
        await model.workspace.loadTasks()
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let window = UIWindow(frame: bounds)
        defer { window.isHidden = true; window.rootViewController = nil }
        for (style, scheme) in [(UIUserInterfaceStyle.dark, ColorScheme.dark), (.light, .light)] {
            for (name, tab) in [("Home", MainTab.home), ("Groups", .groups), ("Tasks", .tasks), ("Activity", .activity), ("Settings", .settings)] {
                model.selectedTab = tab
                let view = MainTabView().environmentObject(model).environmentObject(model.workspace)
                    .environment(\.locale, Locale(identifier: "en_GB")).preferredColorScheme(scheme)
                let host = UIHostingController(rootView: view)
                host.overrideUserInterfaceStyle = style
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.view.frame = bounds
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(400))
                XCTAssertFalse(host.view.subviews.isEmpty, "\(name) should have a rendered view tree")
                let renderer = UIGraphicsImageRenderer(bounds: bounds)
                let image = renderer.image { _ in host.view.drawHierarchy(in: bounds, afterScreenUpdates: true) }
                let attachment = XCTAttachment(image: image)
                attachment.name = "\(name)-\(scheme == .dark ? "dark" : "light")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}

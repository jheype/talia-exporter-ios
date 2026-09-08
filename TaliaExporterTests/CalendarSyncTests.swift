import XCTest
import EventKit
@testable import TaliaExporter

final class CalendarSyncTests: XCTestCase {
    private let owner = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let itemID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    func testTaskAndNoteWithSameIDHaveDifferentStableLinks() throws {
        let due = Date().addingTimeInterval(3600)
        let task = CalendarDeadline(id: itemID, kind: .task, title: "TAL-1 · Check stock", dueAt: due)
        let note = CalendarDeadline(id: itemID, kind: .note, title: "Call the insurer", dueAt: due)
        let entry = task.entry(ownerID: owner, calendarID: "private")
        let noteEntry = note.entry(ownerID: owner, calendarID: "private")
        XCTAssertNotEqual(entry.url, noteEntry.url)
        XCTAssertEqual(entry.endAt.timeIntervalSince(entry.dueAt), 300)
        let moved = CalendarDeadline(id: itemID, kind: .task, title: "New title", dueAt: due.addingTimeInterval(86400))
            .entry(ownerID: owner, calendarID: "different")
        XCTAssertEqual(entry.url, moved.url)
    }

    func testSnapshotRejectsIncompleteAndWrongAccountBeforeRemoval() throws {
        XCTAssertThrowsError(try CalendarDeadlineSnapshot(ownerUserID: owner, complete: false, items: [])
            .entries(for: owner, preferences: CalendarPreferences()))
        XCTAssertThrowsError(try CalendarDeadlineSnapshot(ownerUserID: UUID(), complete: true, items: [])
            .entries(for: owner, preferences: CalendarPreferences()))
    }

    func testPassedDeadlinesStayIdentifiableUntilSourceIsCompletedOrDeleted() throws {
        let now = Date()
        let past = CalendarDeadline(id: itemID, kind: .note, title: "Old", dueAt: now.addingTimeInterval(-60))
        let entry = past.entry(ownerID: owner, calendarID: "private")
        let link = CalendarEventLink(ownerID: owner, url: entry.url, calendarID: "private", dueAt: entry.dueAt,
                                     eventID: "saved-event", externalID: nil)
        let snapshot = CalendarDeadlineSnapshot(ownerUserID: owner, complete: true, items: [past])
        let entries = try snapshot.entries(for: owner, preferences: CalendarPreferences())
        let plan = CalendarReconciliationPlan(existing: [link], entries: entries, ownerID: owner)
        XCTAssertEqual(plan.upsert.count, 1)
        XCTAssertTrue(plan.remove.isEmpty)
        let completed = CalendarReconciliationPlan(existing: [link], entries: [], ownerID: owner)
        XCTAssertEqual(completed.remove.map(\.eventID), ["saved-event"])
    }

    @MainActor
    func testDisabledByDefaultAndPermissionDenialDoesNotFetchDeadlines() async {
        let api = CalendarAPIStub(snapshot: snapshot())
        let events = CalendarEventsStub(granted: false)
        let controller = makeController(api: api, events: events)
        controller.setOwner(owner)
        await controller.refresh(force: true)
        await controller.setEnabled(true)
        XCTAssertFalse(controller.preferences.enabled)
        XCTAssertFalse(controller.isChangingAccess)
        XCTAssertNotNil(controller.errorMessage)
        let requests = await api.requests
        let writes = await events.writes
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testEnableUpdateAndDisableReconcileWithoutDuplicates() async {
        let api = CalendarAPIStub(snapshot: snapshot())
        let events = CalendarEventsStub()
        let controller = makeController(api: api, events: events)
        controller.setOwner(owner)
        await controller.setEnabled(true)
        XCTAssertFalse(controller.isChangingAccess)
        XCTAssertEqual(controller.eventCount, 1)
        await controller.refresh(force: true)
        let entries = await events.entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertNotNil(controller.lastSyncedAt)
        await controller.setEnabled(false)
        let remaining = await events.entries
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(controller.isSyncing)
    }

    @MainActor
    func testFailedSnapshotKeepsExistingReminders() async {
        let api = CalendarAPIStub(snapshot: snapshot())
        let events = CalendarEventsStub()
        let controller = makeController(api: api, events: events)
        controller.setOwner(owner)
        await controller.setEnabled(true)
        await api.setSnapshot(CalendarDeadlineSnapshot(ownerUserID: owner, complete: false, items: []))
        await controller.refresh(force: true)
        let entries = await events.entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertNotNil(controller.errorMessage)
    }

    @MainActor
    func testSignOutDiscardsLateResponseAndRemovesOldAccountEvents() async {
        let api = CalendarAPIStub(snapshot: snapshot())
        let events = CalendarEventsStub()
        let controller = makeController(api: api, events: events)
        controller.setOwner(owner)
        await controller.setEnabled(true)
        let started = expectation(description: "Deadline fetch started")
        await api.blockNextRequest(started)
        let refresh = Task { await controller.refresh(force: true) }
        await fulfillment(of: [started], timeout: 2)
        controller.setOwner(UUID())
        await api.resume()
        await refresh.value
        await controller.waitForCleanup()
        let entries = await events.entries
        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(controller.preferences.enabled)
        XCTAssertEqual(controller.eventCount, 0)
        XCTAssertNil(controller.lastSyncedAt)
    }

    @MainActor
    func testNoteLinksOpenPersonalNotesAndRejectAnotherAccount() {
        let model = AppModel.preview()
        model.user = TaliaUser(id: owner, email: "test@talia.co.uk", role: "team_member", isOwner: false)
        let entry = CalendarDeadline(id: itemID, kind: .note, title: "Private", dueAt: Date())
            .entry(ownerID: owner, calendarID: "private")
        model.openWorkspaceURL(entry.url)
        XCTAssertEqual(model.selectedTab, .tasks)
        XCTAssertEqual(model.workspace.section, .notes)
        XCTAssertEqual(model.workspace.requestedNoteID, itemID)
        model.selectedTab = .home
        let other = CalendarDeadline(id: itemID, kind: .task, title: "Other", dueAt: Date())
            .entry(ownerID: UUID(), calendarID: "private")
        model.openWorkspaceURL(other.url)
        XCTAssertEqual(model.selectedTab, .home)
    }

    func testEventKitCreatesMovesAndRemovesOnlyTaliaEvents() async throws {
        guard ProcessInfo.processInfo.environment["TALIA_CALENDAR_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Run with simulator Calendar access granted; see the iOS CI workflow.")
        }
        XCTAssertEqual(EKEventStore.authorizationStatus(for: .event), .fullAccess)
        let store = EKEventStore()
        let source = try XCTUnwrap(store.defaultCalendarForNewEvents?.source ?? store.sources.first { $0.sourceType == .local })
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Talia test \(UUID())"
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        let calendarID = calendar.calendarIdentifier
        defer {
            if let current = store.calendar(withIdentifier: calendarID) { try? store.removeCalendar(current, commit: true) }
        }
        let now = Date()
        let due = now.addingTimeInterval(3600)
        let foreign = EKEvent(eventStore: store)
        foreign.calendar = calendar
        foreign.title = "Unrelated appointment"
        foreign.startDate = due
        foreign.endDate = due.addingTimeInterval(300)
        try store.save(foreign, span: .thisEvent, commit: true)
        let foreignID = foreign.eventIdentifier
        let suite = "calendar-eventkit-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = EventKitCalendarStore(defaults: defaults)
        let entry = CalendarDeadline(id: itemID, kind: .note, title: "Renew insurance", dueAt: due)
            .entry(ownerID: owner, calendarID: calendarID)
        _ = try await service.synchronise(entries: [entry], ownerID: owner, calendarID: calendarID)
        func readEvents() -> [EKEvent] {
            store.reset()
            guard let currentCalendar = store.calendar(withIdentifier: calendarID) else { return [] }
            return store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-86400),
                end: now.addingTimeInterval(86400), calendars: [currentCalendar]))
        }
        var owned = try XCTUnwrap(readEvents().first { $0.url == entry.url })
        XCTAssertEqual(owned.alarms?.count, 1)
        XCTAssertEqual(owned.alarms?.first?.relativeOffset, 0)
        XCTAssertEqual(owned.startDate.timeIntervalSince(due), 0, accuracy: 1)
        let originalID = owned.eventIdentifier
        let moved = CalendarDeadline(id: itemID, kind: .note, title: "Renew insurance policy", dueAt: due.addingTimeInterval(3600))
            .entry(ownerID: owner, calendarID: calendarID)
        _ = try await service.synchronise(entries: [moved], ownerID: owner, calendarID: calendarID)
        _ = try await service.synchronise(entries: [moved], ownerID: owner, calendarID: calendarID)
        let afterMove = readEvents().filter { $0.url == entry.url }
        XCTAssertEqual(afterMove.count, 1)
        owned = try XCTUnwrap(afterMove.first)
        XCTAssertEqual(owned.eventIdentifier, originalID)
        XCTAssertEqual(owned.startDate.timeIntervalSince(moved.dueAt), 0, accuracy: 1)
        // Simulate an existing event whose deadline has just passed. Its alarm
        // must survive an otherwise unchanged reconciliation.
        let passed = CalendarEntry(ownerID: owner, url: moved.url, calendarID: moved.calendarID,
                                   title: moved.title, dueAt: now.addingTimeInterval(-60))
        owned.startDate = passed.dueAt
        owned.endDate = passed.endAt
        try store.save(owned, span: .thisEvent, commit: true)
        XCTAssertEqual(readEvents().first { $0.url == entry.url }?.alarms?.count, 1,
                       "The existing past event must still have its alarm before reconciliation")
        _ = try await service.synchronise(entries: [passed], ownerID: owner, calendarID: calendarID)
        XCTAssertEqual(readEvents().first { $0.url == entry.url }?.alarms?.count, 1)
        let renamed = CalendarEntry(ownerID: owner, url: passed.url, calendarID: passed.calendarID,
                                    title: "Updated insurance note", dueAt: passed.dueAt)
        _ = try await service.synchronise(entries: [renamed], ownerID: owner, calendarID: calendarID)
        owned = try XCTUnwrap(readEvents().first { $0.url == entry.url })
        XCTAssertEqual(owned.title, renamed.title)
        XCTAssertEqual(owned.alarms?.count, 1, "A title change must preserve an unchanged past deadline's alarm")
        let rescheduledPast = CalendarEntry(ownerID: owner, url: passed.url, calendarID: passed.calendarID,
                                           title: renamed.title, dueAt: passed.dueAt.addingTimeInterval(-3600))
        _ = try await service.synchronise(entries: [rescheduledPast], ownerID: owner, calendarID: calendarID)
        XCTAssertTrue(readEvents().first { $0.url == entry.url }?.alarms?.isEmpty == true,
                      "Moving a deadline into the past must not schedule an immediate alert")
        _ = try await service.synchronise(entries: [], ownerID: owner, calendarID: calendarID)
        let remaining = readEvents()
        XCTAssertFalse(remaining.contains { $0.url == entry.url })
        XCTAssertTrue(remaining.contains { $0.eventIdentifier == foreignID })
        _ = try await service.synchronise(entries: [passed], ownerID: owner, calendarID: calendarID)
        XCTAssertFalse(readEvents().contains { $0.url == entry.url }, "Do not create new past events")
    }

    private func snapshot() -> CalendarDeadlineSnapshot {
        CalendarDeadlineSnapshot(ownerUserID: owner, complete: true, items: [
            CalendarDeadline(id: itemID, kind: .note, title: "Renew insurance", dueAt: Date().addingTimeInterval(3600))
        ])
    }

    @MainActor
    private func makeController(api: CalendarAPIStub, events: CalendarEventsStub) -> CalendarSyncController {
        let name = "calendar-test-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return CalendarSyncController(api: api, events: events, defaults: defaults)
    }
}

actor CalendarAPIStub: CalendarDeadlineServing {
    var requests = 0
    private var snapshot: CalendarDeadlineSnapshot
    private var started: XCTestExpectation?
    private var continuation: CheckedContinuation<CalendarDeadlineSnapshot, Never>?
    init(snapshot: CalendarDeadlineSnapshot) { self.snapshot = snapshot }
    func setSnapshot(_ value: CalendarDeadlineSnapshot) { snapshot = value }
    func blockNextRequest(_ expectation: XCTestExpectation) { started = expectation }
    func resume() { continuation?.resume(returning: snapshot); continuation = nil }
    func calendarDeadlines(preferences: CalendarPreferences) async throws -> CalendarDeadlineSnapshot {
        requests += 1
        if let expectation = started {
            started = nil
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                expectation.fulfill()
            }
        }
        return snapshot
    }
}

actor CalendarEventsStub: CalendarEventServing {
    let granted: Bool
    var entries: [URL: CalendarEntry] = [:]
    var writes = 0
    init(granted: Bool = true) { self.granted = granted }
    func authorisation() -> CalendarAuthorisation { granted ? .fullAccess : .denied }
    func requestAccess() -> Bool { granted }
    func calendars() -> [CalendarDestination] {
        granted ? [CalendarDestination(id: "private", title: "Personal", account: "iCloud", isDefault: true)] : []
    }
    func synchronise(entries: [CalendarEntry], ownerID: UUID, calendarID: String) throws -> Int {
        try Task.checkCancellation()
        writes += 1
        self.entries = Dictionary(uniqueKeysWithValues: entries.map { ($0.url, $0) })
        return entries.count
    }
    func removeEvents(keepingOwner ownerID: UUID?) { entries = entries.filter { $0.value.ownerID == ownerID } }
    func removeEvents(forOwner ownerID: UUID) { entries = entries.filter { $0.value.ownerID != ownerID } }
}

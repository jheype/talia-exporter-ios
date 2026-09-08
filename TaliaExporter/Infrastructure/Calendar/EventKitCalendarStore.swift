import EventKit
import Foundation

/// EventKit and its mutable objects stay on one actor, away from the UI.
/// Committed identities are retained even on a failed or cancelled pass. Stable
/// URLs recover events if the process stops before the ledger is persisted.
actor EventKitCalendarStore: CalendarEventServing {
    private let store = EKEventStore()
    private let defaults: UserDefaults
    private let ledgerKey = "talia.exporter.calendar-links.v1"
    private var links: [String: CalendarEventLink]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: "talia.exporter.calendar-links.v1")
            .flatMap { try? JSONDecoder().decode([CalendarEventLink].self, from: $0) } ?? []
        links = Dictionary(saved.map { ($0.url.absoluteString, $0) }, uniquingKeysWith: { _, last in last })
    }

    func authorisation() -> CalendarAuthorisation {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .fullAccess
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    func calendars() -> [CalendarDestination] {
        guard authorisation() == .fullAccess else { return [] }
        let defaultID = store.defaultCalendarForNewEvents?.calendarIdentifier
        return store.calendars(for: .event).filter(\.allowsContentModifications).map {
            CalendarDestination(id: $0.calendarIdentifier, title: $0.title,
                                account: $0.source.title, isDefault: $0.calendarIdentifier == defaultID)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func synchronise(entries: [CalendarEntry], ownerID: UUID, calendarID: String) throws -> Int {
        try Task.checkCancellation()
        guard authorisation() == .fullAccess else { throw CalendarSyncError.accessDenied }
        guard let calendar = store.calendar(withIdentifier: calendarID), calendar.allowsContentModifications else {
            throw CalendarSyncError.missingCalendar
        }
        guard entries.allSatisfy({ $0.ownerID == ownerID && $0.calendarID == calendarID }) else {
            throw CalendarSyncError.accountMismatch
        }
        defer { persist() }
        let plan = CalendarReconciliationPlan(existing: Array(links.values), entries: entries, ownerID: ownerID)
        for link in plan.remove {
            try Task.checkCancellation()
            try remove(link)
        }
        for entry in plan.upsert {
            try Task.checkCancellation()
            let previous = links[entry.url.absoluteString]
            let matches = try findEvents(url: entry.url, link: previous, calendar: calendar, dueAt: entry.dueAt)
            // Reuse within a source. EventKit cannot reliably move an event
            // between accounts, so a cross-account calendar change replaces it.
            let event = matches.first(where: { $0.calendar?.calendarIdentifier == calendarID }) ??
                matches.first(where: { $0.calendar?.source.sourceIdentifier == calendar.source.sourceIdentifier }) ??
                EKEvent(eventStore: store)
            let needsSave = event.eventIdentifier == nil || event.calendar?.calendarIdentifier != calendarID ||
                event.title != entry.title || event.startDate != entry.dueAt || event.endDate != entry.endAt ||
                event.isAllDay || event.url != entry.url || event.alarms?.count != 1 ||
                event.alarms?.first?.relativeOffset != 0 || event.alarms?.first?.absoluteDate != nil
            let duplicates = matches.filter { $0 !== event }
            do {
                if needsSave {
                    event.calendar = calendar
                    event.title = entry.title
                    event.startDate = entry.dueAt
                    event.endDate = entry.endAt
                    event.timeZone = TimeZone(secondsFromGMT: 0)
                    event.isAllDay = false
                    event.url = entry.url
                    event.notes = "Deadline from Talia. Change the date or complete the item in Talia."
                    event.alarms = [EKAlarm(relativeOffset: 0)]
                    event.availability = calendar.supportedEventAvailabilities.contains(.free) ? .free : .notSupported
                    try store.save(event, span: .thisEvent, commit: false)
                }
                for duplicate in duplicates {
                    try Task.checkCancellation()
                    try store.remove(duplicate, span: .thisEvent, commit: false)
                }
                try Task.checkCancellation()
                if needsSave || !duplicates.isEmpty { try store.commit() }
            } catch {
                store.reset()
                throw error
            }
            links[entry.url.absoluteString] = CalendarEventLink(ownerID: ownerID, url: entry.url, calendarID: calendarID,
                                            dueAt: entry.dueAt, eventID: event.eventIdentifier,
                                            externalID: event.calendarItemExternalIdentifier)
        }
        return entries.count
    }

    func removeEvents(keepingOwner ownerID: UUID?) throws {
        let obsolete = links.values.filter { $0.ownerID != ownerID }
        guard !obsolete.isEmpty else { return }
        guard authorisation() == .fullAccess else { throw CalendarSyncError.accessDenied }
        defer { persist() }
        for link in obsolete {
            try Task.checkCancellation()
            try remove(link)
        }
    }

    func removeEvents(forOwner ownerID: UUID) throws {
        let obsolete = links.values.filter { $0.ownerID == ownerID }
        guard !obsolete.isEmpty else { return }
        guard authorisation() == .fullAccess else { throw CalendarSyncError.accessDenied }
        defer { persist() }
        for link in obsolete {
            try Task.checkCancellation()
            try remove(link)
        }
    }

    private func remove(_ link: CalendarEventLink) throws {
        let calendar = store.calendar(withIdentifier: link.calendarID)
        for event in try findEvents(url: link.url, link: link, calendar: calendar, dueAt: link.dueAt) {
            try Task.checkCancellation()
            try store.remove(event, span: .thisEvent, commit: true)
        }
        links.removeValue(forKey: link.url.absoluteString)
    }

    private func findEvents(url: URL, link: CalendarEventLink?, calendar: EKCalendar?, dueAt: Date) throws -> [EKEvent] {
        var candidates: [EKEvent] = []
        if let id = link?.eventID, let event = store.event(withIdentifier: id) { candidates.append(event) }
        if let id = link?.externalID {
            candidates += store.calendarItems(withExternalIdentifier: id).compactMap { $0 as? EKEvent }
        }
        // Search only the selected/previous calendar around known deadlines. A
        // local EventKit identifier can change after iCloud reconciliation.
        var searches: [(EKCalendar, Date)] = []
        if let calendar { searches.append((calendar, dueAt)) }
        if let link, let old = store.calendar(withIdentifier: link.calendarID) { searches.append((old, link.dueAt)) }
        for (calendar, date) in searches {
            let predicate = store.predicateForEvents(withStart: date.addingTimeInterval(-86400),
                                                     end: date.addingTimeInterval(86400), calendars: [calendar])
            candidates += store.events(matching: predicate)
        }
        if candidates.contains(where: { $0.url == url && $0.hasRecurrenceRules }) {
            throw CalendarSyncError.recurringEvent
        }
        var seen = Set<String>()
        return candidates.filter {
            guard $0.url == url, !$0.hasRecurrenceRules, let id = $0.eventIdentifier else { return false }
            return seen.insert(id).inserted
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Array(links.values)) { defaults.set(data, forKey: ledgerKey) }
    }
}

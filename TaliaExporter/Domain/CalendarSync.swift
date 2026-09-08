import Foundation

struct CalendarPreferences: Codable, Equatable, Sendable {
    var enabled = false
    var calendarID = ""
    var includeTasks = true
    var includeNotes = true
    var assignee = ""
}

struct CalendarDestination: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let account: String
    let isDefault: Bool
}

enum CalendarAuthorisation: Equatable, Sendable {
    case notDetermined, fullAccess, denied
}

struct CalendarDeadline: Decodable, Sendable {
    enum Kind: String, Decodable, Sendable { case task, note }
    let id: UUID
    let kind: Kind
    let title: String
    let dueAt: Date
    enum CodingKeys: String, CodingKey { case id, kind, title; case dueAt = "due_at" }

    func entry(ownerID: UUID, calendarID: String) -> CalendarEntry {
        var url = URLComponents()
        url.scheme = "talia-exporter"
        url.host = kind == .task ? "tasks" : "notes"
        url.queryItems = [.init(name: "account", value: ownerID.uuidString.lowercased()),
                          .init(name: "id", value: id.uuidString.lowercased()),
                          .init(name: "calendar", value: "1")]
        return CalendarEntry(ownerID: ownerID, url: url.url!, calendarID: calendarID,
                             title: kind == .note ? "Note · \(title)" : title, dueAt: dueAt)
    }
}

struct CalendarDeadlineSnapshot: Decodable, Sendable {
    let ownerUserID: UUID
    let complete: Bool
    let items: [CalendarDeadline]
    enum CodingKeys: String, CodingKey { case complete, items; case ownerUserID = "owner_user_id" }

    func entries(for ownerID: UUID, preferences: CalendarPreferences, now: Date = Date()) throws -> [CalendarEntry] {
        guard ownerID == ownerUserID else { throw CalendarSyncError.accountMismatch }
        guard complete else { throw CalendarSyncError.incomplete }
        let entries = items.filter {
            $0.dueAt > now && ($0.kind == .task ? preferences.includeTasks : preferences.includeNotes)
        }.map { $0.entry(ownerID: ownerID, calendarID: preferences.calendarID) }
        guard Set(entries.map(\.url)).count == entries.count else { throw CalendarSyncError.incomplete }
        return entries
    }
}

struct CalendarEntry: Equatable, Sendable {
    let ownerID: UUID
    let url: URL
    let calendarID: String
    let title: String
    let dueAt: Date
    var endAt: Date { dueAt.addingTimeInterval(5 * 60) }
}

/// Only event identities and dates are persisted; task titles and private note text are not cached here.
struct CalendarEventLink: Codable, Sendable {
    let ownerID: UUID
    let url: URL
    let calendarID: String
    let dueAt: Date
    let eventID: String?
    let externalID: String?
}

struct CalendarReconciliationPlan {
    let remove: [CalendarEventLink]
    let upsert: [CalendarEntry]

    init(existing: [CalendarEventLink], entries: [CalendarEntry], ownerID: UUID) {
        let desired = Set(entries.map(\.url))
        remove = existing.filter { $0.ownerID != ownerID || !desired.contains($0.url) }
        upsert = entries
    }
}

enum CalendarSyncError: LocalizedError {
    case accessDenied, missingCalendar, incomplete, accountMismatch, unavailable, recurringEvent
    var errorDescription: String? {
        switch self {
        case .accessDenied: "Allow full Calendar access in iPhone Settings to update or remove Talia reminders."
        case .missingCalendar: "Choose an available calendar that allows new events."
        case .incomplete: "The deadline list is incomplete. Existing reminders were kept. Choose an assignee to reduce the number of tasks, then retry."
        case .accountMismatch: "The deadline response belongs to a different account. No calendar events were changed."
        case .recurringEvent: "An exported event was made recurring in Calendar. Remove its recurrence in Calendar, then retry sync."
        case .unavailable: "Calendar sync needs the updated Talia backend. Existing reminders were kept."
        }
    }
}

protocol CalendarDeadlineServing: Sendable {
    func calendarDeadlines(preferences: CalendarPreferences) async throws -> CalendarDeadlineSnapshot
}

protocol CalendarEventServing: Sendable {
    func authorisation() async -> CalendarAuthorisation
    func requestAccess() async throws -> Bool
    func calendars() async -> [CalendarDestination]
    func synchronise(entries: [CalendarEntry], ownerID: UUID, calendarID: String) async throws -> Int
    func removeEvents(keepingOwner ownerID: UUID?) async throws
    func removeEvents(forOwner ownerID: UUID) async throws
}

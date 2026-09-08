import Combine
import Foundation

@MainActor
final class CalendarSyncController: ObservableObject {
    @Published private(set) var preferences = CalendarPreferences()
    @Published private(set) var destinations: [CalendarDestination] = []
    @Published private(set) var access: CalendarAuthorisation = .notDetermined
    @Published private(set) var isSyncing = false
    @Published private(set) var isChangingAccess = false
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var eventCount = 0
    @Published private(set) var errorMessage: String?
    private(set) var ownerID: UUID?
    var onSessionExpired: ((Error) async -> Void)?

    private let api: (any CalendarDeadlineServing)?
    private let events: any CalendarEventServing
    private let defaults: UserDefaults
    private var revision: UInt64 = 0
    private var accessRevision: UInt64 = 0
    private var syncTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var lastAttemptAt: Date?

    init(api: (any CalendarDeadlineServing)?, events: any CalendarEventServing = EventKitCalendarStore(),
         defaults: UserDefaults = .standard) {
        self.api = api
        self.events = events
        self.defaults = defaults
    }

    func setOwner(_ id: UUID?) {
        guard id != ownerID else { return }
        revision &+= 1
        accessRevision &+= 1
        syncTask?.cancel()
        if let old = ownerID {
            var disabled = preferences
            disabled.enabled = false
            save(disabled, ownerID: old)
        }
        ownerID = id
        preferences = id.flatMap { defaults.data(forKey: key($0)) }
            .flatMap { try? JSONDecoder().decode(CalendarPreferences.self, from: $0) } ?? CalendarPreferences()
        lastSyncedAt = nil
        lastAttemptAt = nil
        eventCount = 0
        isSyncing = false
        isChangingAccess = false
        errorMessage = nil
        let previous = cleanupTask
        let inFlight = syncTask
        let ticket = revision
        cleanupTask = Task { [weak self, events] in
            await previous?.value
            await inFlight?.value
            do { try await events.removeEvents(keepingOwner: id) }
            catch {
                guard let self, self.revision == ticket else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func waitForCleanup() async { await cleanupTask?.value }

    func loadAccess() async {
        let ticket = revision
        let status = await events.authorisation()
        let calendars = await events.calendars()
        guard ticket == revision else { return }
        access = status
        destinations = calendars
    }

    func setEnabled(_ enabled: Bool) async {
        guard let owner = ownerID, !isChangingAccess else { return }
        isChangingAccess = true
        let ticket = accessRevision
        defer { if ticket == accessRevision { isChangingAccess = false } }
        if enabled {
            do {
                let granted = try await events.requestAccess()
                guard ticket == accessRevision, ownerID == owner else { return }
                await loadAccess()
                guard ticket == accessRevision, ownerID == owner else { return }
                guard granted else { throw CalendarSyncError.accessDenied }
                if !destinations.contains(where: { $0.id == preferences.calendarID }) {
                    preferences.calendarID = destinations.first(where: \.isDefault)?.id ?? destinations.first?.id ?? ""
                }
                guard !preferences.calendarID.isEmpty else { throw CalendarSyncError.missingCalendar }
                preferences.enabled = true
                save(preferences, ownerID: owner)
                await refresh(force: true)
            } catch { if ticket == accessRevision { errorMessage = error.localizedDescription } }
        } else {
            revision &+= 1
            preferences.enabled = false
            save(preferences, ownerID: owner)
            syncTask?.cancel()
            await syncTask?.value
            if ticket == accessRevision { isSyncing = false }
            do {
                await cleanupTask?.value
                guard ticket == accessRevision else { return }
                try await events.removeEvents(forOwner: owner)
                guard ticket == accessRevision else { return }
                eventCount = 0
                lastSyncedAt = nil
                errorMessage = nil
            } catch { if ticket == accessRevision { errorMessage = error.localizedDescription } }
        }
    }

    func update(_ edit: (inout CalendarPreferences) -> Void) async {
        guard let ownerID else { return }
        edit(&preferences)
        save(preferences, ownerID: ownerID)
        await refresh(force: true)
    }

    func refresh(force: Bool = false) async {
        guard let owner = ownerID, preferences.enabled, let api else { return }
        if !force && (isSyncing || lastAttemptAt.map { Date().timeIntervalSince($0) < 60 } == true) { return }
        let previous = syncTask
        previous?.cancel()
        revision &+= 1
        let ticket = revision
        let query = preferences
        let cleanup = cleanupTask
        lastAttemptAt = Date()
        isSyncing = true
        let task = Task { [weak self, events] in
            await previous?.value
            guard let self else { return }
            await cleanup?.value
            defer { if self.revision == ticket { self.isSyncing = false } }
            do {
                try Task.checkCancellation()
                await self.loadAccess()
                guard self.access == .fullAccess else { throw CalendarSyncError.accessDenied }
                let snapshot = try await api.calendarDeadlines(preferences: query)
                try Task.checkCancellation()
                guard self.revision == ticket, self.ownerID == owner else { return }
                let entries = try snapshot.entries(for: owner, preferences: query)
                let count = try await events.synchronise(entries: entries, ownerID: owner, calendarID: query.calendarID)
                guard self.revision == ticket, !Task.isCancelled else { return }
                self.eventCount = count
                self.lastSyncedAt = Date()
                self.errorMessage = nil
            } catch {
                guard self.revision == ticket, !Task.isCancelled else { return }
                if let apiError = error as? APIError, apiError.statusCode == 401 || apiError.code == "AUTH.REFRESH_FAILED" {
                    // Invoke outside this task so sign-out cleanup can await its completion.
                    Task { [weak self] in await self?.onSessionExpired?(error) }
                } else if (error as? APIError)?.statusCode == 404 {
                    self.errorMessage = CalendarSyncError.unavailable.localizedDescription
                } else { self.errorMessage = error.localizedDescription }
            }
        }
        syncTask = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    private func key(_ owner: UUID) -> String { "talia.exporter.calendar-preferences.\(owner.uuidString)" }
    private func save(_ preferences: CalendarPreferences, ownerID: UUID) {
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: key(ownerID)) }
    }
}

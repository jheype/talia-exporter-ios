import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var route: AppRoute = .loading
    @Published var selectedTab: MainTab = .home
    @Published var connectionStage: ConnectionStage = .intro
    @Published var user: TaliaUser?
    @Published var session: ExporterSession?
    @Published var groups: [ExportGroup] = []
    @Published var events: [CaptureEvent] = []
    @Published var messages: [CapturedMessage] = []
    @Published var pairingCode: String?
    @Published var pairingExpiresAt: Date?
    @Published var historyRetryingGroupIDs: Set<String> = []
    @Published var isWorking = false
    @Published var alert: AppAlert?
    @Published var appearance: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey)
        }
    }

    let api: any ExporterServing
    let cache: any DashboardCaching
    let pushNotifications: any PushNotificationCoordinating
    var pairingTask: Task<Void, Never>?
    var selectionTask: Task<Void, Never>?
    var selectionTaskID: UUID?
    var selectionRevision: UInt64 = 0
    var stateReadRevision: UInt64 = 0
    var isRefreshingDashboard = false
    var isRefreshingMessages = false
    var messageChangeWatermark: MessageChangeWatermark?
    var messageCatchupCursor: String?
    var messageCatchupTarget: MessageChangeWatermark?
    var messageCatchupHead: MessageChangeWatermark?
    var latestMessageChanges: [UUID: MessageChangeRecord] = [:]

    static let interruptionAlertsKey = "talia.exporter.interruption-alerts"

    private let backgroundRefresh: BackgroundRefreshCoordinator
    private var didBootstrap = false
    private static let appearanceKey = "talia.exporter.appearance"

    init(dependencies: AppDependencies = .live) {
        api = dependencies.api
        cache = dependencies.cache
        backgroundRefresh = dependencies.backgroundRefresh
        pushNotifications = dependencies.pushNotifications

        let savedValue = UserDefaults.standard.string(forKey: Self.appearanceKey)
        appearance = AppearanceMode(rawValue: savedValue ?? "system") ?? .system

        backgroundRefresh.setHandler { [weak self] in
            guard let self else { return false }
            return await self.performBackgroundRefresh()
        }
    }

    deinit {
        pairingTask?.cancel()
        selectionTask?.cancel()
    }

    var captureEnabled: Bool { session?.captureEnabled ?? false }
    var captureIsLive: Bool { captureEnabled && session?.status == .connected }
    var includeMedia: Bool { session?.includeMedia ?? false }
    var selectedGroupCount: Int { groups.lazy.filter(\.isSelected).count }
    var selectedGroupsDescription: String {
        "\(selectedGroupCount) \(selectedGroupCount == 1 ? "group" : "groups")"
    }

    var compactCaptureStatus: String {
        switch session?.status {
        case .reconnecting: "RECONNECTING"
        case .interrupted, .loggedOut: "ATTENTION"
        default: captureIsLive ? "LIVE" : "PAUSED"
        }
    }

    var captureStatusColour: Color {
        switch session?.status {
        case .interrupted, .loggedOut: .red
        case .reconnecting: .orange
        default: captureIsLive ? .taliaLive : .orange
        }
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        do {
            user = try await api.currentUser()
            await restoreCache()

            if let currentSession = try await api.session(), currentSession.isLinked {
                session = currentSession
                route = .main
                await refreshDashboard(showErrors: false)
            } else {
                route = .connection
                connectionStage = .intro
            }
        } catch let error as APIError where error.statusCode == 401 {
            await resetAuthenticatedState()
        } catch {
            route = .signedOut
            present(error, title: "Unable to connect")
        }

        backgroundRefresh.schedule()
    }

    func performBackgroundRefresh() async -> Bool {
        guard user != nil, route == .main, !isRefreshingDashboard else { return true }
        isRefreshingDashboard = true
        defer { isRefreshingDashboard = false }
        stateReadRevision &+= 1
        let requestedStateReadRevision = stateReadRevision
        let requestedSelectionRevision = selectionRevision
        let selectionWasStable = selectionTask == nil
        do {
            let snapshot = try await api.dashboard()
            apply(
                snapshot,
                requestedStateReadRevision: requestedStateReadRevision,
                requestedSelectionRevision: requestedSelectionRevision,
                selectionWasStable: selectionWasStable
            )
            _ = await refreshMessageChanges(showErrors: false, pageBudget: 2)
            await persistDashboard()
            return true
        } catch {
            return false
        }
    }

    func apply(
        _ snapshot: DashboardSnapshot,
        requestedStateReadRevision: UInt64,
        requestedSelectionRevision: UInt64,
        selectionWasStable: Bool
    ) {
        // A GET that started before or during an optimistic selection edit may
        // complete after the PUT. Only a request made from the same stable
        // selection generation may replace selection-derived session/group
        // fields. Events and message changes are independent and remain safe to
        // merge.
        if selectionWasStable,
           selectionTask == nil,
           requestedStateReadRevision == stateReadRevision,
           requestedSelectionRevision == selectionRevision {
            session = snapshot.session
            groups = snapshot.groups
        }
        if requestedStateReadRevision == stateReadRevision {
            events = snapshot.events
        }
        mergeMessages(snapshot.messages)
    }

    func mergeMessages(_ incoming: [CapturedMessage]) {
        var byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for message in messages where latestMessageChanges[message.id] == nil {
            latestMessageChanges[message.id] = message.changeRecord
        }
        for message in incoming {
            let candidate = message.changeRecord
            if let latest = latestMessageChanges[message.id] {
                if candidate.isOlder(than: latest) { continue }
                if !latest.isOlder(than: candidate),
                   latest.isTombstone,
                   !candidate.isTombstone {
                    continue
                }
            }
            latestMessageChanges[message.id] = candidate
            if message.isTombstone {
                byID.removeValue(forKey: message.id)
            } else {
                byID[message.id] = message
            }
        }
        messages = byID.values.sorted { left, right in
            if left.timestamp != right.timestamp {
                return left.timestamp > right.timestamp
            }
            return left.id.uuidString < right.id.uuidString
        }
        pruneMessageChangeLedger()
    }

    private func pruneMessageChangeLedger(limit: Int = 20_000) {
        guard latestMessageChanges.count > limit else { return }
        let activeIDs = Set(messages.map(\.id))
        let tombstoneCapacity = max(0, limit - activeIDs.count)
        let newestTombstones = latestMessageChanges
            .filter { !activeIDs.contains($0.key) }
            .sorted { left, right in
                if left.value.updatedAt != right.value.updatedAt {
                    return left.value.updatedAt > right.value.updatedAt
                }
                return left.key.uuidString > right.key.uuidString
            }
            .prefix(tombstoneCapacity)
        var retained = latestMessageChanges.filter { activeIDs.contains($0.key) }
        for entry in newestTombstones {
            retained[entry.key] = entry.value
        }
        latestMessageChanges = retained
    }

    func restoreCache() async {
        guard let cached = await cache.load() else { return }
        session = cached.session
        groups = cached.groups
        events = cached.events
    }

    func persistDashboard() async {
        guard let session else { return }
        await cache.save(CachedDashboard(session: session, groups: groups, events: events))
    }

    func resetAuthenticatedState() async {
        pairingTask?.cancel()
        selectionTask?.cancel()
        selectionTask = nil
        selectionTaskID = nil
        selectionRevision &+= 1
        stateReadRevision &+= 1
        pushNotifications.unregisterForRemoteNotifications()
        UserDefaults.standard.set(false, forKey: Self.interruptionAlertsKey)
        user = nil
        session = nil
        groups = []
        events = []
        messages = []
        messageChangeWatermark = nil
        messageCatchupCursor = nil
        messageCatchupTarget = nil
        messageCatchupHead = nil
        latestMessageChanges = [:]
        pairingCode = nil
        pairingExpiresAt = nil
        historyRetryingGroupIDs = []
        route = .signedOut
        await cache.clear()
    }

    func present(_ error: Error, title: String) {
        let message = (error as? LocalizedError)?.errorDescription ?? "Please try again."
        alert = AppAlert(title: title, message: message)
    }

    func handle(_ error: Error, title: String) async {
        if let apiError = error as? APIError,
           (apiError.statusCode == 401 || apiError.code == "AUTH.REFRESH_FAILED") {
            await resetAuthenticatedState()
            alert = AppAlert(
                title: "Session expired",
                message: "Sign in to Talia again."
            )
            return
        }
        present(error, title: title)
    }

    static func preview(route: AppRoute = .main) -> AppModel {
        let model = AppModel(dependencies: .preview)
        model.user = PreviewData.user
        model.session = PreviewData.session
        model.groups = PreviewData.groups
        model.events = PreviewData.events
        model.messages = PreviewData.messages
        model.route = route
        return model
    }
}

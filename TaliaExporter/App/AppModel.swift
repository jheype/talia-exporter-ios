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
    var isRefreshingDashboard = false

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
    var includeMedia: Bool { session?.includeMedia ?? true }
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
        guard user != nil, route == .main else { return true }
        do {
            let snapshot = try await api.dashboard()
            apply(snapshot)
            await persistDashboard()
            return true
        } catch {
            return false
        }
    }

    func apply(_ snapshot: DashboardSnapshot) {
        session = snapshot.session
        groups = snapshot.groups
        events = snapshot.events
        messages = snapshot.messages
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
        pushNotifications.unregisterForRemoteNotifications()
        UserDefaults.standard.set(false, forKey: Self.interruptionAlertsKey)
        user = nil
        session = nil
        groups = []
        events = []
        messages = []
        pairingCode = nil
        pairingExpiresAt = nil
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

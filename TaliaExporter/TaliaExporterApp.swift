import Foundation
import SwiftUI
import UIKit
import UserNotifications

@main
struct TaliaExporterApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(appModel)
                .environment(\.locale, Locale(identifier: "en_GB"))
                .preferredColorScheme(appModel.appearance.colorScheme)
                .onReceive(NotificationCenter.default.publisher(for: .exporterPushToken)) { notification in
                    guard let token = notification.object as? String else { return }
                    Task { await appModel.registerDeviceToken(token) }
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    BackgroundRefreshCoordinator.shared.schedule()
                    appModel.registerForRemoteNotificationsIfNeeded()
                    Task { await appModel.refreshDashboard(showErrors: false) }
                }
                .task(id: appModel.user?.id) {
                    appModel.registerForRemoteNotificationsIfNeeded()
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundRefreshCoordinator.shared.register()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationCenter.default.post(name: .exporterPushToken, object: token)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }
}

private extension Notification.Name {
    static let exporterPushToken = Notification.Name("com.talia.exporter.push-token")
}

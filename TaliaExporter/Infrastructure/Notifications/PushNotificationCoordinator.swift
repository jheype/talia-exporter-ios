import UIKit
import UserNotifications

@MainActor
protocol PushNotificationCoordinating: Sendable {
    func isAuthorised() async -> Bool
    func requestAuthorisation() async throws -> Bool
    func registerForRemoteNotifications()
    func unregisterForRemoteNotifications()
}

struct SystemPushNotificationCoordinator: PushNotificationCoordinating {
    func isAuthorised() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            true
        case .notDetermined, .denied:
            false
        @unknown default:
            false
        }
    }

    func requestAuthorisation() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        )
    }

    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    func unregisterForRemoteNotifications() {
        UIApplication.shared.unregisterForRemoteNotifications()
    }
}

struct PreviewPushNotificationCoordinator: PushNotificationCoordinating {
    func isAuthorised() async -> Bool { true }
    func requestAuthorisation() async throws -> Bool { true }
    func registerForRemoteNotifications() {}
    func unregisterForRemoteNotifications() {}
}

import Foundation

extension AppModel {
    func interruptionAlertsEnabled() async -> Bool {
        guard UserDefaults.standard.bool(forKey: Self.interruptionAlertsKey) else { return false }
        return await pushNotifications.isAuthorised()
    }

    func enableInterruptionAlerts() async -> Bool {
        do {
            let granted = try await pushNotifications.requestAuthorisation()
            UserDefaults.standard.set(granted, forKey: Self.interruptionAlertsKey)
            if granted {
                pushNotifications.registerForRemoteNotifications()
            } else {
                alert = AppAlert(
                    title: "Notifications disabled",
                    message: "Enable notifications for Talia Exporter in iPhone Settings."
                )
            }
            return granted
        } catch {
            await handle(error, title: "Notifications unavailable")
            return false
        }
    }

    func disableInterruptionAlerts() async {
        UserDefaults.standard.set(false, forKey: Self.interruptionAlertsKey)
        pushNotifications.unregisterForRemoteNotifications()
        do {
            try await api.unregisterDevices()
        } catch {
            await handle(error, title: "Unable to disable alerts")
        }
    }

    func registerForRemoteNotificationsIfNeeded() {
        guard user != nil, UserDefaults.standard.bool(forKey: Self.interruptionAlertsKey) else { return }
        pushNotifications.registerForRemoteNotifications()
    }

    func registerDeviceToken(_ token: String) async {
        guard user != nil, UserDefaults.standard.bool(forKey: Self.interruptionAlertsKey) else { return }
        do {
            try await api.registerDevice(token: token)
        } catch {
            // The next foreground registration retries without interrupting the user.
        }
    }
}

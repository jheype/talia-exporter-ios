import Foundation

struct AppDependencies: Sendable {
    let api: any ExporterServing
    let cache: any DashboardCaching
    let backgroundRefresh: BackgroundRefreshCoordinator
    let pushNotifications: any PushNotificationCoordinating

    static var live: AppDependencies {
        let baseURL = AppConfiguration.apiBaseURL
        let client = APIClient(baseURL: baseURL)
        return AppDependencies(
            api: ExporterAPI(client: client),
            cache: SecureDashboardCache(),
            backgroundRefresh: .shared,
            pushNotifications: SystemPushNotificationCoordinator()
        )
    }

    static var preview: AppDependencies {
        AppDependencies(
            api: PreviewExporterAPI(),
            cache: InMemoryDashboardCache(),
            backgroundRefresh: .shared,
            pushNotifications: PreviewPushNotificationCoordinator()
        )
    }
}

enum AppConfiguration {
    static var apiBaseURL: URL {
        if let override = ProcessInfo.processInfo.environment["TALIA_API_BASE_URL"],
           let url = validatedBaseURL(override) {
            return url
        }

        if let configured = Bundle.main.object(forInfoDictionaryKey: "TALIA_API_BASE_URL") as? String,
           let url = validatedBaseURL(configured) {
            return url
        }

        return URL(string: "https://api.talia.co.uk/api/v1/")!
    }

    private static func validatedBaseURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              url.host != nil,
              scheme == "https" || allowsInsecureDebugURL(scheme: scheme) else {
            return nil
        }
        return url.normalisedAsDirectory
    }

    private static func allowsInsecureDebugURL(scheme: String) -> Bool {
        #if DEBUG
        return scheme == "http"
        #else
        return false
        #endif
    }
}

private extension URL {
    var normalisedAsDirectory: URL {
        absoluteString.hasSuffix("/") ? self : URL(string: absoluteString + "/")!
    }
}

import Foundation
import Security

struct SARequestError: LocalizedError {
    let status: Int, code: String, message: String
    var errorDescription: String? { message }
}
struct SACredentials: Codable {
    var accessToken: String, refreshToken: String, userID: String, email: String
    var deviceID: String = UUID().uuidString
    var wantsPush = false
    var minimumSeverity = "high"
}
enum SAKeychain {
    private static let service = "com.talia.exporter.superadmin.native"
    static func read(_ owner: UUID) -> SACredentials? {
        var query = base(owner); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SACredentials.self, from: data)
    }
    static func write(_ value: SACredentials, owner: UUID) throws {
        let data = try JSONEncoder().encode(value)
        let update = SecItemUpdate(base(owner) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecItemNotFound {
            var q = base(owner); q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw SARequestError(status: 0, code: "KEYCHAIN", message: "Unable to save the secure session.") }
        } else if update != errSecSuccess { throw SARequestError(status: 0, code: "KEYCHAIN", message: "Unable to update the secure session.") }
    }
    static func remove(_ owner: UUID) { SecItemDelete(base(owner) as CFDictionary) }
    private static func base(_ owner: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: owner.uuidString]
    }
}
/// Independent CRM session. No Exporter cookies or credentials are copied.
private final class SARedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
@MainActor
final class SuperAdminAPI {
    let owner: UUID
    private(set) var credentials: SACredentials?
    private let session: URLSession
    private var refreshTask: Task<Void, Error>?
    private var generation = UUID()
    var onAccessLost: ((String) -> Void)?
    init(owner: UUID, session: URLSession? = nil, restore: Bool = true) {
        self.owner = owner
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData; config.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: config, delegate: SARedirectBlocker(), delegateQueue: nil)
        }
        credentials = restore ? SAKeychain.read(owner) : nil
    }
    func save(_ credentials: SACredentials) throws {
        try SAKeychain.write(credentials, owner: owner); self.credentials = credentials
    }
    func acceptLogin(_ value: SAValue) throws {
        let user = value["user"]
        guard user["isSuperAdmin"].flag, !user["id"].text.isEmpty,
              !value["accessToken"].text.isEmpty, !value["refreshToken"].text.isEmpty else {
            throw SARequestError(status: 403, code: "SA_REQUIRED", message: "This account does not have Super Admin access.")
        }
        var saved = SACredentials(accessToken: value["accessToken"].text, refreshToken: value["refreshToken"].text,
                                  userID: user["id"].text, email: user["email"].text)
        if let previous = credentials, previous.userID == saved.userID {
            saved.deviceID = previous.deviceID; saved.wantsPush = previous.wantsPush; saved.minimumSeverity = previous.minimumSeverity
        }
        try save(saved)
    }
    func request(_ path: String, method: String = "GET", body: [String: SAValue]? = nil, authenticated: Bool = true, requestID: String? = nil) async throws -> SAValue {
        let scope = generation
        do { return try await raw(path, method: method, body: body, token: authenticated ? credentials?.accessToken : nil, requestID: requestID) }
        catch let error as SARequestError where authenticated && error.status == 401 && credentials != nil {
            // Only retry authentication failures; never retry ambiguous mutations.
            do {
                try await refresh()
                guard scope == generation else { throw CancellationError() }
                return try await raw(path, method: method, body: body, token: credentials?.accessToken, requestID: requestID)
            } catch let refreshError as SARequestError where refreshError.status == 401 || refreshError.status == 403 {
                clear(); onAccessLost?(refreshError.message); throw refreshError
            }
        } catch let error as SARequestError where authenticated && error.status == 403 && path.hasPrefix("admin/") {
            onAccessLost?(error.message); throw error
        }
    }
    private func refresh() async throws {
        if let refreshTask { return try await refreshTask.value }
        let scope = generation
        let task = Task { @MainActor in
            guard var saved = credentials else { throw SARequestError(status: 401, code: "SESSION", message: "Sign in to SA Portal.") }
            let value = try await raw("auth/refresh", method: "POST", body: ["refreshToken": .string(saved.refreshToken)], token: nil)
            guard scope == generation else { throw CancellationError() }
            guard !value["accessToken"].text.isEmpty, !value["refreshToken"].text.isEmpty else { throw SARequestError(status: 502, code: "SESSION", message: "Invalid session response.") }
            saved.accessToken = value["accessToken"].text; saved.refreshToken = value["refreshToken"].text
            try save(saved)
        }
        refreshTask = task; defer { refreshTask = nil }; try await task.value
    }
    private func raw(_ path: String, method: String, body: [String: SAValue]?, token: String?, requestID: String? = nil) async throws -> SAValue {
        guard !path.hasPrefix("/"), !path.contains("://"), !path.contains(".."),
              let url = URL(string: "https://app.taliaai.com/api/v1/" + path), url.host == "app.taliaai.com" else { throw URLError(.badURL) }
        let scope = generation
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TaliaExporter/iOS", forHTTPHeaderField: "User-Agent")
        request.setValue("ios", forHTTPHeaderField: "X-Talia-Client")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let requestID { request.setValue(requestID, forHTTPHeaderField: "Idempotency-Key"); request.setValue(requestID, forHTTPHeaderField: "X-Request-ID") }
        if let body { request.httpBody = try JSONEncoder().encode(SAValue.object(body)); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard scope == generation, !Task.isCancelled else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let value = (try? JSONDecoder().decode(SAValue.self, from: data)) ?? .null
        guard (200..<300).contains(http.statusCode) else {
            let message = value.first("message", "error")
            throw SARequestError(status: http.statusCode, code: value["code"].text,
                message: message.isEmpty ? (value["error"]["message"].text.isEmpty ? "Request failed (\(http.statusCode)). Try refreshing." : value["error"]["message"].text) : message)
        }
        if !data.isEmpty && value.isNull { throw SARequestError(status: 502, code: "RESPONSE", message: "The server returned an unexpected response.") }
        return value
    }
    func signOut() async throws {
        if let saved = credentials {
            if saved.wantsPush {
                do { _ = try await request("admin/mobile/devices/\(saved.deviceID)", method: "DELETE") }
                catch let error as SARequestError where error.status == 404 { /* Older server has no device registration. */ }
            }
            _ = try await raw("auth/logout", method: "POST", body: ["refreshToken": .string(saved.refreshToken)], token: credentials?.accessToken)
        }
        clear()
    }
    /// Invalidate pending reads synchronously on Exporter account changes.
    /// Best-effort server logout uses a separate request and cannot revive local state.
    func retire() {
        let previous = credentials
        clear(); session.invalidateAndCancel()
        guard let previous else { return }
        Task {
            let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
            let cleanup = URLSession(configuration: config, delegate: SARedirectBlocker(), delegateQueue: nil)
            defer { cleanup.finishTasksAndInvalidate() }
            var request = URLRequest(url: URL(string: "https://app.taliaai.com/api/v1/auth/logout")!)
            request.httpMethod = "POST"; request.setValue("Bearer \(previous.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(["refreshToken": previous.refreshToken])
            _ = try? await cleanup.data(for: request)
        }
    }
    func clear() { generation = UUID(); refreshTask?.cancel(); refreshTask = nil; credentials = nil; SAKeychain.remove(owner) }
}

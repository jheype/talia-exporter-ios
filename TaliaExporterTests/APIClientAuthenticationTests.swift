import Foundation
import XCTest
@testable import TaliaExporter

final class APIClientAuthenticationTests: XCTestCase {
    func testLoginRequestDoesNotCarryPreviousAccountsCookies() async throws {
        let baseURL = URL(string: "https://account-isolation.test/api/v1/")!
        let cookieStorage = HTTPCookieStorage.shared
        let staleCookies = ["access_token", "refresh_token"].compactMap { name in
            HTTPCookie(properties: [
                .domain: "account-isolation.test",
                .path: "/",
                .name: name,
                .value: "joao-token",
                .secure: "TRUE",
                .expires: Date().addingTimeInterval(3_600)
            ])
        }
        staleCookies.forEach(cookieStorage.setCookie)
        defer { staleCookies.forEach(cookieStorage.deleteCookie) }

        let observed = LockedCookieHeader()
        CookieObservingURLProtocol.observe { request in
            observed.set(request.value(forHTTPHeaderField: "Cookie"))
        }
        defer { CookieObservingURLProtocol.observe(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = cookieStorage
        configuration.protocolClasses = [CookieObservingURLProtocol.self]
        let client = APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
        let api = ExporterAPI(client: client)

        _ = try await api.signIn(email: "lucas@talia.co.uk", password: "secret")

        XCTAssertNil(observed.get())
    }
}

private final class LockedCookieHeader: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func set(_ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class CookieObservingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var observer: ((URLRequest) -> Void)?

    static func observe(_ observer: ((URLRequest) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        self.observer = observer
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let observer = Self.observer
        Self.lock.unlock()
        observer?(request)

        let payload = #"{"user":{"id":"22222222-2222-2222-2222-222222222222","email":"lucas@talia.co.uk","role":"team_member","is_owner":false}}"#.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}


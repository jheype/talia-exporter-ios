import Foundation

enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

struct APIError: LocalizedError, Equatable, Sendable {
    let statusCode: Int?
    let code: String
    let message: String

    var errorDescription: String? { message }

    static func transport(_ error: Error) -> APIError {
        APIError(
            statusCode: nil,
            code: "NETWORK.UNAVAILABLE",
            message: (error as? URLError)?.userFacingMessage ?? "The service could not be reached."
        )
    }
}

private extension URLError {
    var userFacingMessage: String {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost:
            "Check your internet connection and try again."
        case .timedOut:
            "The request timed out. Please try again."
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            "The Talia service is currently unavailable."
        default:
            "The service could not be reached."
        }
    }
}

actor APIClient {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var refreshTask: Task<Void, Error>?

    init(baseURL: URL, session: URLSession = APIClient.makeSession()) {
        self.baseURL = baseURL
        self.session = session

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = ISO8601DateFormatter.withFractionalSeconds.date(from: value)
                ?? ISO8601DateFormatter.standard.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO 8601 date: \(value)"
            )
        }
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    func send<Response: Decodable & Sendable>(
        _ method: HTTPMethod,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: (any Encodable & Sendable)? = nil,
        response: Response.Type = Response.self,
        allowsRefresh: Bool = true
    ) async throws -> Response {
        let request = try makeRequest(method, path: path, queryItems: queryItems, body: body)

        do {
            return try await perform(request, response: response)
        } catch let error as APIError where error.statusCode == 401 && allowsRefresh {
            try await refreshSession()
            let retriedRequest = try makeRequest(method, path: path, queryItems: queryItems, body: body)
            return try await perform(retriedRequest, response: response)
        }
    }

    func sendWithoutResponse(
        _ method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)? = nil,
        allowsRefresh: Bool = true
    ) async throws {
        let request = try makeRequest(method, path: path, queryItems: [], body: body)

        do {
            try await performWithoutResponse(request)
        } catch let error as APIError where error.statusCode == 401 && allowsRefresh {
            try await refreshSession()
            let retriedRequest = try makeRequest(method, path: path, queryItems: [], body: body)
            try await performWithoutResponse(retriedRequest)
        }
    }

    func clearAuthenticationCookies() {
        guard let storage = session.configuration.httpCookieStorage else { return }
        for cookie in storage.cookies(for: baseURL) ?? [] {
            storage.deleteCookie(cookie)
        }
    }

    private func refreshSession() async throws {
        if let refreshTask {
            return try await refreshTask.value
        }

        let task = Task { [baseURL, session] in
            guard let refreshURL = Self.endpointURL(
                baseURL: baseURL,
                path: "auth/refresh"
            ) else {
                throw APIError(
                    statusCode: nil,
                    code: "CLIENT.INVALID_URL",
                    message: "Invalid service URL."
                )
            }
            var request = URLRequest(url: refreshURL)
            request.httpMethod = HTTPMethod.post.rawValue
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("ios", forHTTPHeaderField: "X-Talia-Client")

            let result: (Data, URLResponse)
            do {
                result = try await session.data(for: request)
            } catch {
                throw APIError.transport(error)
            }
            guard let response = result.1 as? HTTPURLResponse else {
                throw APIError(
                    statusCode: nil,
                    code: "NETWORK.INVALID_RESPONSE",
                    message: "Invalid server response."
                )
            }
            guard (200..<300).contains(response.statusCode) else {
                let sessionExpired = response.statusCode == 401 || response.statusCode == 403
                throw APIError(
                    statusCode: response.statusCode,
                    code: sessionExpired ? "AUTH.REFRESH_FAILED" : "AUTH.UNAVAILABLE",
                    message: sessionExpired
                        ? "Your session has expired. Please sign in again."
                        : "Authentication is temporarily unavailable."
                )
            }
        }
        refreshTask = task

        do {
            try await task.value
            refreshTask = nil
        } catch {
            refreshTask = nil
            if let apiError = error as? APIError, apiError.code == "AUTH.REFRESH_FAILED" {
                clearAuthenticationCookies()
            }
            throw error
        }
    }

    private func makeRequest(
        _ method: HTTPMethod,
        path: String,
        queryItems: [URLQueryItem],
        body: (any Encodable & Sendable)?
    ) throws -> URLRequest {
        guard let endpointURL = Self.endpointURL(baseURL: baseURL, path: path) else {
            throw APIError(statusCode: nil, code: "CLIENT.INVALID_URL", message: "Invalid service URL.")
        }
        var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false)
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        guard let url = components?.url else {
            throw APIError(statusCode: nil, code: "CLIENT.INVALID_URL", message: "Invalid service URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.timeoutInterval = method == .get ? 30 : 45
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-GB", forHTTPHeaderField: "Accept-Language")
        request.setValue("ios", forHTTPHeaderField: "X-Talia-Client")

        if let body {
            request.httpBody = try encoder.encode(AnyEncodable(body))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func perform<Response: Decodable & Sendable>(
        _ request: URLRequest,
        response: Response.Type
    ) async throws -> Response {
        let data: Data
        let rawResponse: URLResponse
        do {
            (data, rawResponse) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        guard let httpResponse = rawResponse as? HTTPURLResponse else {
            throw APIError(statusCode: nil, code: "NETWORK.INVALID_RESPONSE", message: "Invalid server response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw parseError(statusCode: httpResponse.statusCode, data: data)
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError(
                statusCode: httpResponse.statusCode,
                code: "CLIENT.INVALID_RESPONSE",
                message: "The server returned an unsupported response."
            )
        }
    }

    private func performWithoutResponse(_ request: URLRequest) async throws {
        let data: Data
        let rawResponse: URLResponse
        do {
            (data, rawResponse) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        guard let response = rawResponse as? HTTPURLResponse else {
            throw APIError(statusCode: nil, code: "NETWORK.INVALID_RESPONSE", message: "Invalid server response.")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw parseError(statusCode: response.statusCode, data: data)
        }
    }

    private func parseError(statusCode: Int, data: Data) -> APIError {
        var code = "HTTP.\(statusCode)"
        var message = HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = object["detail"] as? [String: Any] {
                code = detail["code"] as? String ?? code
                message = detail["message"] as? String ?? message
            } else if let detail = object["detail"] as? String {
                message = detail
            } else {
                code = object["code"] as? String ?? code
                message = object["message"] as? String
                    ?? object["error"] as? String
                    ?? message
            }
        }
        return APIError(statusCode: statusCode, code: code, message: message)
    }

    private static func endpointURL(baseURL: URL, path: String) -> URL? {
        guard path.hasPrefix("/") else {
            return baseURL.appending(path: path)
        }

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = .shared
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        encodeValue = { encoder in
            try value.encode(to: encoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}

private extension ISO8601DateFormatter {
    static let standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

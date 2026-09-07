import Foundation

/// Shares the Exporter's cookie session and refresh single-flight; never creates a second login.
actor WorkspaceAPI {
    let client: APIClient

    init(client: APIClient) { self.client = client }

    func tasks(_ filters: WorkFilters, cursor: String? = nil) async throws -> WorkTaskPage {
        try await client.send(.get, path: "exporter/tasks", queryItems: filters.queryItems(cursor: cursor))
    }

    func task(_ id: UUID) async throws -> WorkTask {
        try await client.send(.get, path: "exporter/tasks/\(id.uuidString)")
    }

    func list<Item: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) async throws -> [Item] {
        let result: WorkList<Item> = try await client.send(.get, path: path, queryItems: query)
        return result.items
    }

    func logs(severity: String, search: String, cursor: String?) async throws -> WorkCursorPage<WorkLog> {
        var query = [URLQueryItem(name: "limit", value: "50")]
        if !severity.isEmpty { query.append(.init(name: "severity", value: severity)) }
        if !search.isEmpty { query.append(.init(name: "search", value: search)) }
        if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        return try await client.send(.get, path: "exporter/logs", queryItems: query)
    }

    func canvas(_ boardID: UUID) async throws -> WorkCanvas {
        try await client.send(.get, path: "exporter/idea-boards/\(boardID.uuidString)")
    }

    func idea(_ id: UUID) async throws -> WorkIdea {
        try await client.send(.get, path: "exporter/ideas/\(id.uuidString)")
    }

    func write<Response: Decodable & Sendable>(
        _ method: HTTPMethod, path: String, body: [String: WorkValue],
        response: Response.Type = Response.self
    ) async throws -> Response {
        try await client.send(method, path: path, body: body, response: response)
    }

    func remove(_ path: String, body: [String: WorkValue]? = nil) async throws {
        try await client.sendWithoutResponse(.delete, path: path, body: body)
    }

    func clearColumn(_ status: WorkStatus) async throws {
        try await client.sendWithoutResponse(
            .post, path: "exporter/tasks/clear", body: ["status": WorkValue.string(status.rawValue)]
        )
    }

    func uploadImage(_ data: Data, ideaID: UUID) async throws {
        try await client.uploadJPEG(data, path: "task-ideas/\(ideaID.uuidString)/images")
    }

    func imageAccess(_ id: UUID, isIdea: Bool) async throws -> WorkImageAccess {
        let path = isIdea
            ? "task-ideas/images/\(id.uuidString)/access"
            : "uk-chat-intelligence/media/\(id.uuidString)/access"
        return try await client.send(.get, path: path, queryItems: [.init(name: "variant", value: "thumbnail")])
    }
}

struct WorkImageAccess: Decodable, Sendable {
    let url: URL
}

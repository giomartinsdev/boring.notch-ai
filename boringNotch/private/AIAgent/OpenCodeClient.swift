//
//  OpenCodeClient.swift
//  boringNotch
//
//  Thin async wrapper around the opencode REST + SSE API.
//

import Foundation

enum OpenCodeError: LocalizedError {
    case http(Int, String)
    case encoding

    var errorDescription: String? {
        switch self {
        case let .http(code, body):
            return "opencode server returned \(code). \(body)"
        case .encoding:
            return "Failed to encode request body."
        }
    }
}

struct OpenCodeClient {
    let server: OpenCodeServerManager
    private let urlSession: URLSession

    init(server: OpenCodeServerManager) {
        self.server = server
        self.urlSession = URLSession(configuration: .default)
    }

    // MARK: - Request building

    private func makeRequest(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) throws -> URLRequest {
        guard var components = URLComponents(url: server.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw OpenCodeError.encoding
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        var request = URLRequest(url: components.url ?? server.baseURL)
        request.httpMethod = method
        request.setValue(server.authHeader(), forHTTPHeaderField: "Authorization")
        for (key, value) in server.workspaceHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    // MARK: - Generic REST

    func data(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> Data {
        let request = try makeRequest(path, method: method, query: query, body: body)
        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw OpenCodeError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    func decode<T: Decodable>(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil,
        as type: T.Type
    ) async throws -> T {
        let data = try await data(path, method: method, query: query, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func encode(_ value: some Encodable) throws -> Data {
        try JSONEncoder().encode(value)
    }

    // MARK: - SSE event stream

    /// Streams `session.next.*` events for a session until the task is cancelled.
    func eventStream(sessionID: String) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try makeRequest("api/session/\(sessionID)/event")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let bytes = try await urlSession.bytes(for: request)
                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { continue }
                        let payload: String
                        if trimmed.hasPrefix("data:") {
                            payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        } else if trimmed.hasPrefix("{") {
                            payload = trimmed
                        } else {
                            continue
                        }
                        guard let eventData = payload.data(using: .utf8),
                              let event = try? JSONDecoder().decode(AgentEvent.self, from: eventData) else {
                            continue
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

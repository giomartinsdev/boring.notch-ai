//
//  OpenCodeModels.swift
//  boringNotch
//
//  Native data models for controlling a local opencode agent server.
//  These mirror the opencode REST + SSE API discovered from its web client:
//    - sessions:   GET/POST  /api/session
//    - transcript: GET        /api/session/{id}/history
//    - live feed:  GET        /api/session/{id}/event   (Server-Sent Events)
//    - prompts:    POST       /api/session/{id}/prompt  body { "prompt": { "text": ... } }
//    - permissions: GET        /api/session/{id}/permission
//                   POST       /api/session/{id}/permission/{requestID}/reply  { "allow": bool }
//    - questions:  GET        /api/session/{id}/question
//                   POST       /api/session/{id}/question/{requestID}/reply    { "text": ... }
//  Every request must carry the Basic auth header and the
//  `x-opencode-workspace` / `x-opencode-directory` headers.
//

import Foundation

// MARK: - Type-erased JSON value (opencode's event `data` is free-form)

indirect enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var string: String? {
        if case let .string(value) = self { value } else { nil }
    }

    var object: [String: JSONValue]? {
        if case let .object(value) = self { value } else { nil }
    }

    var array: [JSONValue]? {
        if case let .array(value) = self { value } else { nil }
    }

    subscript(_ key: String) -> JSONValue? {
        if case let .object(dict) = self { dict[key] } else { nil }
    }

    subscript(_ index: Int) -> JSONValue? {
        if case let .array(list) = self, list.indices.contains(index) { list[index] } else { nil }
    }
}

// MARK: - Sessions

struct ModelInfo: Codable, Equatable, Hashable {
    let id: String
    let providerID: String
    var variant: String?
}

struct OpenCodeSession: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let projectID: String?
    var agent: String?
    var model: ModelInfo?
    var cost: Double?
    var title: String?

    var displayName: String {
        if let agent, !agent.isEmpty {
            return "\(agent)"
        }
        return String(id.prefix(12))
    }
}

// MARK: - Live events (SSE + history share the same envelope)

struct DurableInfo: Codable, Equatable {
    let aggregateID: String
    let seq: Int
    let version: Int
}

struct AgentEvent: Identifiable, Codable, Equatable {
    let id: String
    let type: String
    let durable: DurableInfo?
    let data: JSONValue?

    var seq: Int { durable?.seq ?? 0 }
}

// MARK: - Permission & question requests

struct PermissionRequest: Identifiable, Codable, Equatable {
    let id: String
    let tool: String?
    let action: String?
    let input: JSONValue?
    let sessionID: String?

    var summary: String {
        if let tool, !tool.isEmpty {
            return tool
        }
        if let action, !action.isEmpty {
            return action
        }
        return "Permission request"
    }
}

struct QuestionRequest: Identifiable, Codable, Equatable {
    let id: String
    let question: String?
    let options: [String]?
}

// MARK: - View-model facing derived types

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

struct DisplayMessage: Identifiable, Equatable {
    let id: String
    let role: MessageRole
    let text: String
}

//
//  AgentWire.swift
//  boringNotch
//
//  Wire protocol shared with the OpenCode bridge plugin
//  (boring-notch-opencode.js). All messages are single-line JSON objects.
//
//  Plugin → App:
//    hello          { instanceID, serverUrl, authHeader, managed, directory, pid }
//    event          { type, sessionID, directory?, title?, text?, reply?, ... }
//    permission     { requestID, sessionID, permission, patterns, label, command, description }
//    question       { requestID, sessionID, questions: [ { question, header, options, multiple, custom } ] }
//    command.result { id, ok, status, body? / error? }
//    ping           { instanceID }
//
//  App → Plugin (on the same connection):
//    directive      { requestID, type: allow | always | deny | answer | cancel, answers?, reason? }
//    command        { id, method, path, body? }   (executed through the plugin's in-process fetch)
//

import Foundation

// MARK: - Type-erased JSON value

indirect enum AgentJSON: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AgentJSON])
    case array([AgentJSON])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Double.self) { self = .number(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode([String: AgentJSON].self) { self = .object(v); return }
        if let v = try? container.decode([AgentJSON].self) { self = .array(v); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    var string: String? { if case .string(let v) = self { v } else { nil } }
    var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    var object: [String: AgentJSON]? { if case .object(let v) = self { v } else { nil } }
    var array: [AgentJSON]? { if case .array(let v) = self { v } else { nil } }

    subscript(key: String) -> AgentJSON? { object?[key] }
    subscript(index: Int) -> AgentJSON? {
        guard let a = array, a.indices.contains(index) else { return nil }
        return a[index]
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: AgentJSON?) -> T? {
        guard let value else { return nil }
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Envelope

struct AgentWireMessage: Decodable {
    let v: Int?
    let kind: String
    let data: AgentJSON?
}

struct AgentWireOutgoing: Encodable {
    let v: Int
    let kind: String
    let data: AgentJSON?
}

// MARK: - Hello

struct AgentInstanceInfo: Identifiable, Equatable {
    let id: String          // instanceID from the plugin
    var serverUrl: String
    var authHeader: String?
    var managed: Bool
    var directory: String
    var pid: Int?
    var lastSeen: Date

    var shortDirectory: String {
        (directory as NSString).lastPathComponent
    }
}

// MARK: - Events

enum AgentEvent {
    case sessionStart(sessionID: String, directory: String?, title: String?)
    case sessionEnd(sessionID: String)
    case sessionTitle(sessionID: String, title: String)
    case sessionBusy(sessionID: String)
    case sessionIdle(sessionID: String, reply: String?)
    case sessionError(sessionID: String, message: String)
    case promptSent(sessionID: String, text: String)
    case assistantText(sessionID: String, text: String)
    case toolStart(sessionID: String, tool: String, detail: String?)
    case toolEnd(sessionID: String, tool: String, status: String)
    case permissionSettled(sessionID: String, requestID: String?)
    case questionSettled(sessionID: String, requestID: String?)

    /// Parses the normalized event payload sent by the plugin.
    /// Returns the event plus the session it belongs to.
    static func parse(_ data: AgentJSON) -> (sessionID: String, event: AgentEvent)? {
        guard let sessionID = data["sessionID"]?.string else { return nil }
        let type = data["type"]?.string ?? ""
        switch type {
        case "session.start":
            return (sessionID, .sessionStart(
                sessionID: sessionID,
                directory: data["directory"]?.string,
                title: data["title"]?.string))
        case "session.end":
            return (sessionID, .sessionEnd(sessionID: sessionID))
        case "session.title":
            guard let title = data["title"]?.string else { return nil }
            return (sessionID, .sessionTitle(sessionID: sessionID, title: title))
        case "session.busy":
            return (sessionID, .sessionBusy(sessionID: sessionID))
        case "session.idle":
            return (sessionID, .sessionIdle(sessionID: sessionID, reply: data["reply"]?.string))
        case "session.error":
            return (sessionID, .sessionError(sessionID: sessionID, message: data["message"]?.string ?? "Unknown error"))
        case "prompt.sent":
            guard let text = data["text"]?.string else { return nil }
            return (sessionID, .promptSent(sessionID: sessionID, text: text))
        case "assistant.text":
            guard let text = data["text"]?.string else { return nil }
            return (sessionID, .assistantText(sessionID: sessionID, text: text))
        case "tool.start":
            return (sessionID, .toolStart(
                sessionID: sessionID,
                tool: data["tool"]?.string ?? "tool",
                detail: data["detail"]?.string))
        case "tool.end":
            return (sessionID, .toolEnd(
                sessionID: sessionID,
                tool: data["tool"]?.string ?? "tool",
                status: data["status"]?.string ?? "ok"))
        case "permission.settled":
            return (sessionID, .permissionSettled(sessionID: sessionID, requestID: data["requestID"]?.string))
        case "question.settled":
            return (sessionID, .questionSettled(sessionID: sessionID, requestID: data["requestID"]?.string))
        default:
            return nil
        }
    }
}

// MARK: - Permission / Question requests (pending user action)

struct AgentPendingPermission: Identifiable, Equatable {
    let id: String            // requestID
    let sessionID: String
    let instanceID: String
    var permission: String
    var patterns: [String]
    var label: String
    var command: String
    var descriptionText: String
    var directory: String?
    var arrivedAt: Date

    static func parse(_ data: AgentJSON, instanceID: String) -> AgentPendingPermission? {
        guard let id = data["requestID"]?.string,
              let sessionID = data["sessionID"]?.string else { return nil }
        return AgentPendingPermission(
            id: id,
            sessionID: sessionID,
            instanceID: instanceID,
            permission: data["permission"]?.string ?? "",
            patterns: data["patterns"]?.array?.compactMap(\.string) ?? [],
            label: data["label"]?.string ?? "Permission",
            command: data["command"]?.string ?? "",
            descriptionText: data["description"]?.string ?? "",
            directory: data["directory"]?.string,
            arrivedAt: Date())
    }
}

struct AgentQuestionOption: Identifiable, Equatable {
    let label: String
    let detail: String
    var id: String { label }
}

struct AgentQuestionItem: Identifiable, Equatable {
    let question: String
    let header: String
    let options: [AgentQuestionOption]
    var multiple: Bool
    var custom: Bool
    var id: String { header.isEmpty ? question : header }

    static func parse(_ json: AgentJSON) -> AgentQuestionItem? {
        guard let question = json["question"]?.string else { return nil }
        let options = (json["options"]?.array ?? []).compactMap { opt -> AgentQuestionOption? in
            guard let label = opt["label"]?.string else { return nil }
            return AgentQuestionOption(label: label, detail: opt["description"]?.string ?? "")
        }
        guard !options.isEmpty else { return nil }
        return AgentQuestionItem(
            question: question,
            header: json["header"]?.string ?? "",
            options: options,
            multiple: json["multiple"]?.bool ?? false,
            custom: json["custom"]?.bool ?? false)
    }
}

struct AgentPendingQuestion: Identifiable, Equatable {
    let id: String
    let sessionID: String
    let instanceID: String
    var questions: [AgentQuestionItem]
    var directory: String?
    var arrivedAt: Date

    static func parse(_ data: AgentJSON, instanceID: String) -> AgentPendingQuestion? {
        guard let id = data["requestID"]?.string,
              let sessionID = data["sessionID"]?.string else { return nil }
        let questions = (data["questions"]?.array ?? []).compactMap(AgentQuestionItem.parse)
        guard !questions.isEmpty else { return nil }
        return AgentPendingQuestion(
            id: id,
            sessionID: sessionID,
            instanceID: instanceID,
            questions: questions,
            directory: data["directory"]?.string,
            arrivedAt: Date())
    }
}

// MARK: - Directives (App → Plugin replies to held requests)

struct AgentDirective {
    enum Kind {
        case allow
        case always
        case deny(reason: String?)
        case answer(answers: [[String]])
        case cancel
    }

    let requestID: String
    let kind: Kind

    func encode() -> AgentWireOutgoing {
        var payload: [String: AgentJSON] = ["requestID": .string(requestID)]
        switch kind {
        case .allow:
            payload["type"] = .string("allow")
        case .always:
            payload["type"] = .string("always")
        case .deny(let reason):
            payload["type"] = .string("deny")
            if let reason { payload["reason"] = .string(reason) }
        case .answer(let answers):
            payload["type"] = .string("answer")
            payload["answers"] = .array(answers.map { .array($0.map(AgentJSON.string)) })
        case .cancel:
            payload["type"] = .string("cancel")
        }
        return AgentWireOutgoing(v: 1, kind: "directive", data: .object(payload))
    }
}

// MARK: - REST passthrough models (decoded from command results)

struct OCSessionList: Decodable {
    struct Item: Decodable, Identifiable {
        let id: String
        var agent: String?
        var title: String?
        var cost: Double?
        struct ModelRef: Decodable { let id: String; let providerID: String }
        var model: ModelRef?
        struct TimeInfo: Decodable { let created: Double?; var updated: Double? }
        var time: TimeInfo?
        struct Location: Decodable { let directory: String? }
        var location: Location?
    }
    let data: [Item]
}

struct OCMessageList: Decodable {
    struct Item: Decodable, Identifiable {
        let id: String
        var type: String?
        var text: String?
        struct Part: Decodable { let type: String?; let text: String? }
        var content: [Part]?
        struct TimeInfo: Decodable { let created: Double? }
        var time: TimeInfo?
        var error: AgentJSON?
    }
    let data: [Item]
    var cursor: AgentJSON?
}

struct OCModelList: Decodable {
    struct Item: Decodable, Identifiable {
        let id: String
        let providerID: String
        var name: String?
        var status: String?
    }
    let data: [Item]
}

struct OCSessionCreated: Decodable {
    struct Item: Decodable { let id: String }
    let data: Item
}

/// A parsed chat message ready for display.
struct AgentChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant, error }
    let id: String
    let role: Role
    let text: String
}

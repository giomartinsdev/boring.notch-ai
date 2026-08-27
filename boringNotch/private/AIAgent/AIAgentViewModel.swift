//
//  AIAgentViewModel.swift
//  boringNotch
//
//  Bridges the opencode client to the SwiftUI UI. A single shared instance
//  backs both the compact notch panel and the full control window so their
//  state stays in sync.
//

import Foundation
import Combine
import Defaults

@MainActor
final class AIAgentViewModel: ObservableObject {
    static let shared = AIAgentViewModel()

    let server = OpenCodeServerManager.shared
    private let client: OpenCodeClient

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)
    }

    @Published var connectionState: ConnectionState = .disconnected
    @Published var sessions: [OpenCodeSession] = []
    @Published var selectedSessionID: String?
    @Published var events: [AgentEvent] = []
    @Published var pendingPermissions: [PermissionRequest] = []
    @Published var pendingQuestions: [QuestionRequest] = []
    @Published var promptText: String = ""
    @Published var agentStatus: String = "Idle"
    @Published var isWorking: Bool = false

    private var streamTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    init() {
        client = OpenCodeClient(server: server)
    }

    // MARK: - Activation

    func activate() {
        guard Defaults[.aiAgentEnabled] else { return }
        server.start()
        Task { await connect() }
    }

    /// Connects only if we haven't already tried — safe to call from view lifecycle.
    func ensureConnected() {
        guard Defaults[.aiAgentEnabled] else { return }
        if connectionState == .disconnected {
            activate()
        }
    }

    func connect() async {
        guard Defaults[.aiAgentEnabled] else { return }
        connectionState = .connecting
        for _ in 0..<60 {
            if await server.healthOK() { break }
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard await server.healthOK() else {
            connectionState = .error("Could not reach the opencode server.")
            return
        }
        connectionState = .connected
        await refreshSessions()
        if selectedSessionID == nil, let first = sessions.first {
            selectedSessionID = first.id
        }
        if let sessionID = selectedSessionID {
            await openSession(sessionID)
        } else {
            await createSession()
        }
    }

    // MARK: - Sessions

    func refreshSessions() async {
        do {
            struct ListResponse: Decodable { let data: [OpenCodeSession] }
            let response = try await client.decode(
                "api/session",
                query: [URLQueryItem(name: "location", value: "{\"workspace\":\"\(server.workspace)\",\"directory\":\"\(server.workspace)\"}")],
                as: ListResponse.self
            )
            sessions = response.data
        } catch {
            connectionState = .error("Failed to list sessions: \(error.localizedDescription)")
        }
    }

    func createSession() async {
            struct CreateResponse: Decodable { let data: OpenCodeSession }
        let payload: [String: Any] = [
            "agent": "build",
            "location": ["workspace": server.workspace, "directory": server.workspace]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        do {
            let response = try await client.decode("api/session", method: "POST", body: body, as: CreateResponse.self)
            if !sessions.contains(where: { $0.id == response.data.id }) {
                sessions.insert(response.data, at: 0)
            }
            await openSession(response.data.id)
        } catch {
            connectionState = .error("Failed to create session: \(error.localizedDescription)")
        }
    }

    func openSession(_ sessionID: String) async {
        selectedSessionID = sessionID
        pendingPermissions = []
        pendingQuestions = []
        await loadHistory()
        startStreaming()
        startPolling()
    }

    func selectSession(_ sessionID: String) {
        Task { await openSession(sessionID) }
    }

    // MARK: - Transcript

    func loadHistory() async {
        guard let sessionID = selectedSessionID else { return }
        do {
            struct HistoryResponse: Decodable { let data: [AgentEvent]; let hasMore: Bool }
            let response = try await client.decode("api/session/\(sessionID)/history", as: HistoryResponse.self)
            events = response.data.sorted { $0.seq < $1.seq }
            recomputeStatus()
        } catch {
            // Non-fatal: the live stream will fill in.
        }
    }

    private func startStreaming() {
        streamTask?.cancel()
        guard let sessionID = selectedSessionID else { return }
        streamTask = Task {
            do {
                for try await event in client.eventStream(sessionID: sessionID) {
                    await MainActor.run {
                        if !self.events.contains(where: { $0.id == event.id }) {
                            self.events.append(event)
                            self.events.sort { $0.seq < $1.seq }
                            self.recomputeStatus()
                        }
                    }
                }
            } catch is CancellationError {
                // expected on cancel
            } catch {
                // ignore stream errors; polling keeps the UI alive
            }
        }
    }

    // MARK: - Polling for permission / question prompts

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await pollPrompts()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    func pollPrompts() async {
        guard let sessionID = selectedSessionID else { return }
        do {
            struct PermissionResponse: Decodable { let data: [PermissionRequest] }
            let permissions = try await client.decode("api/session/\(sessionID)/permission", as: PermissionResponse.self)
            await MainActor.run { self.pendingPermissions = permissions.data }
        } catch { /* ignore */ }
        do {
            struct QuestionResponse: Decodable { let data: [QuestionRequest] }
            let questions = try await client.decode("api/session/\(sessionID)/question", as: QuestionResponse.self)
            await MainActor.run { self.pendingQuestions = questions.data }
        } catch { /* ignore */ }
    }

    // MARK: - Actions

    func sendPrompt() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sessionID = selectedSessionID, !text.isEmpty else { return }
        promptText = ""
        Task {
            let payload: [String: Any] = ["prompt": ["text": text]]
            guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
            do {
                _ = try await client.data("api/session/\(sessionID)/prompt", method: "POST", body: body)
            } catch {
                await MainActor.run { self.connectionState = .error("Failed to send prompt: \(error.localizedDescription)") }
            }
        }
    }

    func approve(_ requestID: String) { replyPermission(requestID, allow: true) }
    func deny(_ requestID: String) { replyPermission(requestID, allow: false) }

    private func replyPermission(_ requestID: String, allow: Bool) {
        guard let sessionID = selectedSessionID else { return }
        Task {
            let payload: [String: Any] = ["allow": allow]
            guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
            do {
                _ = try await client.data("api/session/\(sessionID)/permission/\(requestID)/reply", method: "POST", body: body)
                await MainActor.run { self.pendingPermissions.removeAll { $0.id == requestID } }
            } catch { /* ignore */ }
        }
    }

    func answerQuestion(_ requestID: String, text: String) {
        guard let sessionID = selectedSessionID else { return }
        Task {
            let payload: [String: Any] = ["text": text]
            guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
            do {
                _ = try await client.data("api/session/\(sessionID)/question/\(requestID)/reply", method: "POST", body: body)
                await MainActor.run { self.pendingQuestions.removeAll { $0.id == requestID } }
            } catch { /* ignore */ }
        }
    }

    func interrupt() {
        guard let sessionID = selectedSessionID else { return }
        Task {
            _ = try? await client.data("api/session/\(sessionID)/interrupt", method: "POST")
        }
    }

    // MARK: - Deriving UI state from events

    private func recomputeStatus() {
        guard let last = events.last else {
            agentStatus = "Idle"
            isWorking = false
            return
        }
        let type = last.type
        if type.contains("step.started") || type.contains("prompted") || type.contains("prompt.admitted") {
            agentStatus = "Working…"
            isWorking = true
        } else if type.contains("step.failed") {
            agentStatus = "Error"
            isWorking = false
        } else if type.contains("step.completed") || type.contains("message") {
            agentStatus = "Idle"
            isWorking = false
        } else {
            agentStatus = "Idle"
            isWorking = false
        }
    }

    var displayMessages: [DisplayMessage] {
        var messages: [DisplayMessage] = []
        var seenMessageIDs = Set<String>()
        for event in events {
            if event.type.contains("prompt") {
                guard let data = event.data,
                      let text = data["prompt"]?["text"]?.string, !text.isEmpty else { continue }
                let mid = data["messageID"]?.string ?? event.id
                if seenMessageIDs.contains(mid) { continue }
                seenMessageIDs.insert(mid)
                messages.append(DisplayMessage(id: mid, role: .user, text: text))
            } else if event.type.contains("message") {
                guard let text = Self.extractText(from: event.data?["message"]), !text.isEmpty else { continue }
                messages.append(DisplayMessage(id: event.id, role: .assistant, text: text))
            } else if event.type == "session.next.step.failed" {
                if let error = event.data?["error"]?["message"]?.string, !error.isEmpty {
                    let mid = "err-\(event.id)"
                    if !seenMessageIDs.contains(mid) {
                        seenMessageIDs.insert(mid)
                        messages.append(DisplayMessage(id: mid, role: .system, text: "⚠️ \(error)"))
                    }
                }
            }
        }
        return messages
    }

    static func extractText(from message: JSONValue?) -> String {
        guard let message else { return "" }
        if let parts = message["parts"]?.array {
            var result = ""
            for part in parts {
                if part["type"]?.string == "text", let text = part["text"]?.string {
                    if !result.isEmpty { result += "\n" }
                    result += text
                }
            }
            if !result.isEmpty { return result }
        }
        if let content = message["content"]?.string, !content.isEmpty { return content }
        if let text = message["text"]?.string, !text.isEmpty { return text }
        return ""
    }

    var connectionLabel: String {
        switch connectionState {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return server.isRunning ? "Connected" : "Connected (external)"
        case let .error(message): return message
        }
    }
}

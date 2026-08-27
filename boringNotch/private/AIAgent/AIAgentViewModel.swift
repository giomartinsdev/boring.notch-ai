//
//  AIAgentViewModel.swift
//  boringNotch
//
//  Central state for the OpenCode agent integration: connection tracking,
//  live session store, pending approval cards, and chat driving through
//  the bridge command channel.
//

import Foundation
import Combine
import Defaults
import AppKit
import SwiftUI

// MARK: - Session model

struct AgentSession: Identifiable, Equatable {
    enum Phase: Equatable {
        case busy
        case idle
        case waitingApproval
        case waitingAnswer
        case errored
    }

    let id: String
    var instanceID: String?
    var title: String
    var directory: String?
    var phase: Phase = .idle
    var wasBusy = false
    var lastPrompt: String?
    var lastReply: String?
    var lastTool: String?
    var modelRef: String?
    var updatedAt = Date()

    var project: String {
        guard let dir = directory, !dir.isEmpty else { return "opencode" }
        return (dir as NSString).lastPathComponent
    }

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("New session") {
            return lastPrompt.map { String($0.prefix(48)) } ?? "Session \(id.suffix(6))"
        }
        return String(t.prefix(64))
    }

    static func == (lhs: AgentSession, rhs: AgentSession) -> Bool {
        lhs.id == rhs.id && lhs.phase == rhs.phase && lhs.title == rhs.title
            && lhs.instanceID == rhs.instanceID
    }
}

// MARK: - Done notification card

struct AgentDoneCard: Identifiable, Equatable {
    let id = UUID()
    let sessionID: String
    var title: String
    var reply: String
    var instanceID: String?
    var createdAt = Date()
}

// MARK: - View model

@MainActor
final class AIAgentViewModel: ObservableObject, AgentBridgeDelegate {
    static let shared = AIAgentViewModel()

    let bridge = AgentBridgeServer()

    // Connection
    @Published private(set) var instances: [AgentInstanceInfo] = []
    @Published private(set) var connected: Bool = false
    @Published private(set) var everConnected: Bool = false

    // Sessions
    @Published private(set) var sessions: [AgentSession] = []
    @Published var selectedSessionID: String?

    // Pending user action
    @Published private(set) var pendingPermissions: [AgentPendingPermission] = []
    @Published private(set) var pendingQuestions: [AgentPendingQuestion] = []
    @Published private(set) var doneCards: [AgentDoneCard] = []
    @Published var cardDismissedIDs: Set<String> = []

    // Chat state
    @Published private(set) var messages: [AgentChatMessage] = []
    @Published private(set) var chatLoading = false
    @Published private(set) var sending = false
    @Published private(set) var availableModels: [OCModelList.Item] = []
    @Published var modelPickerShowing = false

    private var reloadDebounce: Task<Void, Never>?
    private var doneCardCleanupTask: Task<Void, Never>?
    private var started = false
    private var openCodeProcess: Process?

    var hasPendingApproval: Bool {
        !pendingPermissions.isEmpty || !pendingQuestions.isEmpty
    }

    /// The card that should take over the open notch surface, if any.
    var activePermission: AgentPendingPermission? {
        pendingPermissions.first { !cardDismissedIDs.contains($0.id) }
    }

    var activeQuestion: AgentPendingQuestion? {
        pendingQuestions.first { !cardDismissedIDs.contains($0.id) }
    }

    var activeDoneCard: AgentDoneCard? {
        doneCards.first
    }

    var selectedSession: AgentSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    var selectedInstanceID: String? {
        guard let s = selectedSession else { return bridge.primaryInstanceID }
        return s.instanceID ?? bridge.primaryInstanceID
    }

    // MARK: Lifecycle

    func activate() {
        guard Defaults[.aiAgentEnabled] else { return }
        guard !started else { return }
        started = true

        let ok = bridge.start(delegate: self)
        if !ok {
            NSLog("[Agent] failed to start bridge server")
        }
        AgentPluginInstaller.ensureInstalled()
        launchOpenCodeIfNeeded(force: false)
    }

    func restart() {
        bridge.stop()
        started = false
        activate()
    }

    // MARK: Managed OpenCode launch

    /// Launches OpenCode as a managed, persistent instance so the user can
    /// chat directly from the panel without starting it themselves. OpenCode
    /// needs a pseudo-terminal to run its TUI, so we wrap it in `script`.
    /// `respectAutoLaunch` honours the `aiAgentAutoLaunch` setting; pass false
    /// to always attempt (e.g. an explicit button tap).
    func launchManagedOpenCode(respectAutoLaunch: Bool = true) {
        launchOpenCodeIfNeeded(force: !respectAutoLaunch)
    }

    private func launchOpenCodeIfNeeded(force: Bool) {
        guard force || Defaults[.aiAgentAutoLaunch] else { return }
        guard bridge.primaryInstanceID == nil else { return }
        guard openCodeProcess == nil || openCodeProcess?.isRunning != true else { return }

        let binary = resolveOpenCodeBinary()
        guard !binary.isEmpty else {
            NSLog("[Agent] OpenCode binary not found; cannot launch managed instance")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", binary]
        let ws = Defaults[.aiAgentWorkspace].isEmpty ? NSHomeDirectory() : Defaults[.aiAgentWorkspace]
        process.currentDirectoryURL = URL(fileURLWithPath: ws)

        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["HOME"] = home
        env["USER"] = NSUserName()
        env["LOGNAME"] = NSUserName()
        env["SHELL"] = "/bin/zsh"
        env["TERM"] = "xterm-256color"
        env["BORING_NOTCH_MANAGED"] = "1"
        let extra = (home as NSString).appendingPathComponent(".opencode/bin")
        let fallbackPath = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = [extra, env["PATH"], fallbackPath].compactMap { $0 }.joined(separator: ":")
        process.environment = env

        process.standardInput = nil
        process.standardOutput = nil
        process.standardError = nil

        do {
            try process.run()
            openCodeProcess = process
            NSLog("[Agent] launched managed OpenCode: \(binary) (dir: \(ws))")
        } catch {
            NSLog("[Agent] failed to launch OpenCode: \(error)")
        }
    }

    private func resolveOpenCodeBinary() -> String {
        let configured = Defaults[.aiAgentServerBinary]
        if !configured.isEmpty, FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }
        if let p = which("opencode"), !p.isEmpty, FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        let common = (NSHomeDirectory() as NSString).appendingPathComponent(".opencode/bin/opencode")
        if FileManager.default.isExecutableFile(atPath: common) { return common }
        return ""
    }

    private func which(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = [name]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    // MARK: AgentBridgeDelegate

    func bridge(didRegisterInstance info: AgentInstanceInfo) {
        everConnected = true
        refreshInstances()
        Task { await backfillSessions(instanceID: info.id) }
        Task { await fetchModels(instanceID: info.id) }
    }

    func bridge(didLoseInstance instanceID: String) {
        refreshInstances()
        // Mark sessions owned by the lost instance as stale.
        for i in sessions.indices where sessions[i].instanceID == instanceID {
            sessions[i].instanceID = nil
            if sessions[i].phase == .busy { sessions[i].phase = .idle }
        }
        // Drop cards from dead instances.
        pendingPermissions.removeAll { $0.instanceID == instanceID }
        pendingQuestions.removeAll { $0.instanceID == instanceID }
    }

    func bridgeDidUpdateInstances(count: Int) {
        refreshInstances()
    }

    private func refreshInstances() {
        let infos = bridge.instanceInfos
        instances = infos.sorted { $0.lastSeen > $1.lastSeen }
        connected = !infos.isEmpty
    }

    // MARK: Events

    func bridge(didReceiveEvent event: AgentEvent, sessionID: String, instanceID: String) {
        switch event {
        case let .sessionStart(sid, directory, title):
            upsertSession(id: sid, instanceID: instanceID, directory: directory, title: title)

        case let .sessionEnd(sid):
            sessions.removeAll { $0.id == sid }
            if selectedSessionID == sid { selectedSessionID = nil }

        case let .sessionTitle(sid, title):
            upsertSession(id: sid, instanceID: instanceID) { s in
                s.title = title
            }

        case let .sessionBusy(sid):
            upsertSession(id: sid, instanceID: instanceID) { s in
                s.phase = .busy
                s.wasBusy = true
            }

        case let .sessionIdle(sid, reply):
            var shouldNotify = false
            var wasBusy = false
            upsertSession(id: sid, instanceID: instanceID) { s in
                wasBusy = s.wasBusy
                s.phase = .idle
                s.wasBusy = false
                if let reply, !reply.isEmpty {
                    s.lastReply = reply
                    if wasBusy { shouldNotify = true }
                }
            }
            if shouldNotify, let reply, Defaults[.aiAgentNotifyOnDone] {
                let title = sessions.first { $0.id == sid }?.displayTitle ?? "opencode"
                let card = AgentDoneCard(sessionID: sid, title: title, reply: reply, instanceID: instanceID)
                presentDoneCard(card)
            }

        case let .sessionError(sid, message):
            upsertSession(id: sid, instanceID: instanceID) { s in
                s.phase = .errored
                s.lastReply = message
                s.wasBusy = false
            }

        case let .promptSent(sid, text):
            upsertSession(id: sid, instanceID: instanceID) { s in
                s.lastPrompt = stripWrappingQuotes(text)
            }

        case let .assistantText(sid, text):
            upsertSession(id: sid, instanceID: instanceID) { s in
                s.lastReply = text
            }

        case let .toolStart(sid, tool, _):
            upsertSession(id: sid, instanceID: instanceID) { s in
                s.lastTool = tool
            }

        case .toolEnd:
            break

        case let .permissionSettled(sid, requestID):
            if let rid = requestID {
                pendingPermissions.removeAll { $0.id == rid }
                cardDismissedIDs.remove(rid)
            } else {
                // Some settle event for this session — refresh state.
                upsertSession(id: sid, instanceID: instanceID) { s in
                    if s.phase == .waitingApproval { s.phase = .busy }
                }
            }

        case let .questionSettled(sid, requestID):
            if let rid = requestID {
                pendingQuestions.removeAll { $0.id == rid }
                cardDismissedIDs.remove(rid)
            } else {
                upsertSession(id: sid, instanceID: instanceID) { s in
                    if s.phase == .waitingAnswer { s.phase = .busy }
                }
            }
        }

        // Live chat refresh for the visible conversation.
        switch event {
        case .promptSent, .assistantText, .toolStart, .toolEnd:
            scheduleChatReload()
        default:
            break
        }
    }

    func bridge(didReceivePermission permission: AgentPendingPermission) {
        pendingPermissions.append(permission)
        if let i = sessions.firstIndex(where: { $0.id == permission.sessionID }) {
            sessions[i].phase = .waitingApproval
        }
        presentApprovalCard()
    }

    func bridge(didReceiveQuestion question: AgentPendingQuestion) {
        pendingQuestions.append(question)
        if let i = sessions.firstIndex(where: { $0.id == question.sessionID }) {
            sessions[i].phase = .waitingAnswer
        }
        presentApprovalCard()
    }

    // MARK: Session store helpers

    private func upsertSession(
        id: String,
        instanceID: String?,
        directory: String? = nil,
        title: String? = nil,
        mutate: ((inout AgentSession) -> Void)? = nil
    ) {
        if let i = sessions.firstIndex(where: { $0.id == id }) {
            sessions[i].instanceID = instanceID ?? sessions[i].instanceID
            if let directory { sessions[i].directory = directory }
            if let title { sessions[i].title = title }
            mutate?(&sessions[i])
            sessions[i].updatedAt = Date()
        } else {
            var s = AgentSession(
                id: id,
                instanceID: instanceID,
                title: title ?? "",
                directory: directory)
            mutate?(&s)
            s.updatedAt = Date()
            sessions.append(s)
        }
        sortSessions()
    }

    private func sortSessions() {
        func rank(_ s: AgentSession) -> Int {
            switch s.phase {
            case .waitingApproval, .waitingAnswer: return 0
            case .busy: return 1
            case .errored: return 2
            case .idle: return 3
            }
        }
        sessions.sort { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return a.updatedAt > b.updatedAt
        }
    }

    private func backfillSessions(instanceID: String) async {
        guard let list: OCSessionList = await bridge.command(
            on: instanceID, method: "GET", path: "/api/session", as: OCSessionList.self) else { return }

        let known = Set(sessions.map(\.id))
        for item in list.data.prefix(30) {
            if known.contains(item.id) {
                upsertSession(id: item.id, instanceID: instanceID) { s in
                    if let t = item.title { s.title = t }
                    if let m = item.model { s.modelRef = "\(m.providerID)/\(m.id)" }
                }
                continue
            }
            var s = AgentSession(
                id: item.id,
                instanceID: instanceID,
                title: item.title ?? "",
                directory: item.location?.directory)
            if let m = item.model { s.modelRef = "\(m.providerID)/\(m.id)" }
            s.updatedAt = Date(timeIntervalSince1970: (item.time?.updated ?? item.time?.created ?? 0) / 1000)
            sessions.append(s)
        }
        sortSessions()
    }

    // MARK: Cards

    private func presentApprovalCard() {
        // Notification window observes view model directly
    }

    private func presentDoneCard(_ card: AgentDoneCard) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            doneCards.append(card)
        }
        scheduleDoneCardCleanup()
    }

    private func scheduleDoneCardCleanup() {
        doneCardCleanupTask?.cancel()
        doneCardCleanupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            self?.dismissOldestDoneCard()
        }
    }

    func dismissOldestDoneCard() {
        withAnimation(.easeOut(duration: 0.2)) {
            if !doneCards.isEmpty { doneCards.removeFirst() }
        }
    }

    func dismissCard(_ id: String) {
        cardDismissedIDs.insert(id)
    }

    // MARK: Answering permissions / questions

    func approve(permission: AgentPendingPermission, always: Bool = false) {
        pendingPermissions.removeAll { $0.id == permission.id }
        cardDismissedIDs.remove(permission.id)
        bridge.respond(
            to: permission.id,
            directive: AgentDirective(requestID: permission.id, kind: always ? .always : .allow))
        if let i = sessions.firstIndex(where: { $0.id == permission.sessionID }) {
            sessions[i].phase = .busy
        }
    }

    func deny(permission: AgentPendingPermission) {
        pendingPermissions.removeAll { $0.id == permission.id }
        cardDismissedIDs.remove(permission.id)
        bridge.respond(
            to: permission.id,
            directive: AgentDirective(requestID: permission.id, kind: .deny(reason: "Denied from Boring Notch")))
        if let i = sessions.firstIndex(where: { $0.id == permission.sessionID }) {
            sessions[i].phase = .idle
        }
    }

    func answer(question: AgentPendingQuestion, answers: [[String]]) {
        pendingQuestions.removeAll { $0.id == question.id }
        cardDismissedIDs.remove(question.id)
        bridge.respond(
            to: question.id,
            directive: AgentDirective(requestID: question.id, kind: .answer(answers: answers)))
        if let i = sessions.firstIndex(where: { $0.id == question.sessionID }) {
            sessions[i].phase = .busy
        }
    }

    // MARK: Chat

    func openChat(sessionID: String) {
        selectedSessionID = sessionID
        messages = []
        Task { await loadMessages() }
    }

    func closeChat() {
        selectedSessionID = nil
        messages = []
    }

    private func scheduleChatReload() {
        guard selectedSessionID != nil else { return }
        reloadDebounce?.cancel()
        reloadDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.loadMessages()
        }
    }

    func loadMessages() async {
        guard let sessionID = selectedSessionID,
              let instanceID = selectedInstanceID else { return }
        chatLoading = true
        defer { chatLoading = false }

        guard let list: OCMessageList = await bridge.command(
            on: instanceID, method: "GET", path: "/api/session/\(sessionID)/message",
            as: OCMessageList.self) else {
            return
        }

        var parsed: [AgentChatMessage] = []
        for item in list.data.reversed() {
            if item.type == "user" {
                if let t = item.text, !t.isEmpty {
                    parsed.append(AgentChatMessage(id: item.id, role: .user, text: stripWrappingQuotes(t)))
                }
            } else if item.type == "assistant" {
                var text = (item.content ?? [])
                    .filter { $0.type == "text" }
                    .compactMap(\.text)
                    .joined(separator: "\n\n")
                if text.isEmpty, let err = item.error {
                    // Surface provider errors inline.
                    if let msg = err["data"]?["message"]?.string ?? err["message"]?.string {
                        text = "⚠️ \(msg)"
                    }
                }
                if !text.isEmpty {
                    parsed.append(AgentChatMessage(id: item.id, role: .assistant, text: text))
                }
            }
        }
        // If we're showing a busy indicator keep the live lastReply as the
        // final (still streaming) message when history hasn't caught up.
        messages = parsed
    }

    func sendPrompt(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let sessionID = selectedSessionID,
              let instanceID = selectedInstanceID else { return }

        messages.append(AgentChatMessage(id: "local-\(UUID().uuidString)", role: .user, text: text))
        if let i = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[i].lastPrompt = text
        }

        sending = true
        defer { sending = false }

        let body = AgentJSON.object(["prompt": .object(["text": .string(text)])])
        let result = await bridge.command(
            on: instanceID, method: "POST",
            path: "/api/session/\(sessionID)/prompt", body: body)
        if !result.ok {
            messages.append(AgentChatMessage(
                id: "err-\(UUID().uuidString)", role: .error,
                text: "Failed to send: \(result.error ?? "status \(result.status)")"))
        }
    }

    func interrupt() {
        guard let sessionID = selectedSessionID,
              let instanceID = selectedInstanceID else { return }
        Task {
            _ = await bridge.command(
                on: instanceID, method: "POST",
                path: "/api/session/\(sessionID)/interrupt")
        }
    }

    func startNewSession() async {
        guard let instanceID = bridge.primaryInstanceID else { return }
        guard let created: OCSessionCreated = await bridge.command(
            on: instanceID, method: "POST", path: "/api/session",
            body: .object(["agent": .string("build")]), as: OCSessionCreated.self) else { return }
        upsertSession(id: created.data.id, instanceID: instanceID, title: "")
        openChat(sessionID: created.data.id)
    }

    // MARK: Models

    func fetchModels(instanceID: String) async {
        guard let list: OCModelList = await bridge.command(
            on: instanceID, method: "GET", path: "/api/model", as: OCModelList.self) else { return }
        let active = list.data.filter { $0.status != "deprecated" }
        availableModels = active.sorted {
            ($0.name ?? $0.id) < ($1.name ?? $1.id)
        }
    }

    func switchModel(_ model: OCModelList.Item) async {
        guard let sessionID = selectedSessionID,
              let instanceID = selectedInstanceID else { return }
        let body = AgentJSON.object([
            "model": .object([
                "id": .string(model.id),
                "providerID": .string(model.providerID),
            ]),
        ])
        let result = await bridge.command(
            on: instanceID, method: "POST",
            path: "/api/session/\(sessionID)/model", body: body)
        if result.ok {
            if let i = sessions.firstIndex(where: { $0.id == sessionID }) {
                sessions[i].modelRef = "\(model.providerID)/\(model.id)"
            }
        }
    }

    var selectedModel: OCModelList.Item? {
        guard let session = selectedSession else { return nil }
        return availableModels.first {
            $0.providerID + "/" + $0.id == session.modelRef
        }
    }
}

// MARK: - Helpers

private func stripWrappingQuotes(_ s: String) -> String {
    var t = s
    if t.count > 1 && t.hasPrefix("\"") && t.hasSuffix("\"") {
        t = String(t.dropFirst().dropLast())
    }
    return t
}

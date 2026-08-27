//
//  AgentBridgeServer.swift
//  boringNotch
//
//  TCP localhost bridge server the OpenCode bridge plugin connects to.
//  Handles the persistent channel protocol: hello registration, live events,
//  held permission/question requests, and REST command passthrough.
//
//  Why TCP and not a Unix domain socket: Boring Notch is an App-Sandboxed
//  macOS app. A sandboxed app cannot share a filesystem path (such as a
//  Unix socket in /tmp or ~/Library/Application Support) with the external
//  opencode process that loads the plugin. localhost TCP works across that
//  boundary and is already covered by the network.server / network.client
//  entitlements. The app scans a small fixed port range for a free port;
//  the plugin scans the same range to discover it.

import Foundation
import AppKit
import os.log

private let agentBridgeLog = OSLog(subsystem: "com.boringnotch.agent", category: "bridge")

private func blog(_ msg: String) {
    os_log("%{public}@", log: agentBridgeLog, type: .info, msg)
}

// MARK: - Connection wrapper

final class AgentBridgeConnection {
    let fd: Int32
    private var writeLock = NSLock()
    var instanceID: String?
    var lastSeen = Date()

    init(fd: Int32) {
        self.fd = fd
    }

    func send(_ message: AgentWireOutgoing) -> Bool {
        guard let data = try? JSONEncoder().encode(message) else { return false }
        var payload = data
        payload.append(0x0A)
        return payload.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            writeLock.lock()
            defer { writeLock.unlock() }
            var sent = 0
            let total = payload.count
            while sent < total {
                let n = write(fd, base + sent, total - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    func touch() { lastSeen = Date() }
}

// MARK: - Command continuations

struct AgentCommandResult {
    let ok: Bool
    let status: Int
    let body: AgentJSON?
    let error: String?
}

final class AgentCommandTicket {
    let id = UUID().uuidString.prefix(8).description
    let continuation: CheckedContinuation<AgentCommandResult, Never>
    init(continuation: CheckedContinuation<AgentCommandResult, Never>) {
        self.continuation = continuation
    }
}

// MARK: - Server delegate (main actor)

@MainActor
protocol AgentBridgeDelegate: AnyObject {
    func bridge(didRegisterInstance info: AgentInstanceInfo)
    func bridge(didLoseInstance instanceID: String)
    func bridge(didReceiveEvent event: AgentEvent, sessionID: String, instanceID: String)
    func bridge(didReceivePermission permission: AgentPendingPermission)
    func bridge(didReceiveQuestion question: AgentPendingQuestion)
    func bridgeDidUpdateInstances(count: Int)
}

// MARK: - Server

final class AgentBridgeServer: @unchecked Sendable {
    /// Scan this small range for a free localhost port. Keep in sync with the
    /// PORT_RANGE in boring-notch-opencode.js.
    static let portBase = 8742
    static let portRange: [Int] = Array(portBase..<(portBase + 11))
    static let bridgeHost = "127.0.0.1"

    private weak var delegate: (any AgentBridgeDelegate)?
    private var listenFD: Int32 = -1
    private var boundPort: Int = 0
    private var running = false
    private let queue = DispatchQueue(label: "boringnotch.agent-bridge", attributes: .concurrent)

    // Instance channels — accessed from socket threads; guarded by lock.
    private let channelsLock = NSLock()
    private var channels: [String: AgentBridgeConnection] = [:]
    private var instances: [String: AgentInstanceInfo] = [:]

    // Command tickets
    private let ticketsLock = NSLock()
    private var tickets: [String: AgentCommandTicket] = [:]

    // Held request reply writers (requestID → send closure)
    private let heldLock = NSLock()
    private var heldRepliers: [String: (AgentDirective) -> Void] = [:]

    private var staleCheckTimer: DispatchSourceTimer?

    func start(delegate: any AgentBridgeDelegate) -> Bool {
        self.delegate = delegate
        stop()

        var boundFD: Int32 = -1
        var chosenPort: Int = 0
        for port in Self.portRange {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                blog("socket() failed: errno \(errno)")
                return false
            }

            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            addr.sin_addr.s_addr = inet_addr(Self.bridgeHost)

            let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindResult != 0 {
                close(fd)
                continue
            }

            if listen(fd, 16) != 0 {
                close(fd)
                continue
            }

            boundFD = fd
            chosenPort = port
            break
        }

        guard boundFD >= 0 else {
            blog("could not bind any bridge port in range \(Self.portBase)-\(Self.portBase + Self.portRange.count - 1); bridge unavailable")
            return false
        }

        listenFD = boundFD
        boundPort = chosenPort
        running = true
        blog("listening on \(Self.bridgeHost):\(chosenPort)")

        Thread.detachNewThread { [weak self] in
            self?.acceptLoop()
        }

        startStaleCheck()
        return true
    }

    func stop() {
        running = false
        staleCheckTimer?.cancel()
        staleCheckTimer = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        channelsLock.lock()
        let all = Array(channels.values)
        channels.removeAll()
        instances.removeAll()
        channelsLock.unlock()
        all.forEach { _ = $0.send(AgentWireOutgoing(v: 1, kind: "ack", data: nil)) }
        blog("bridge stopped")
    }

    // MARK: Accept + read loop

    private func acceptLoop() {
        while running {
            var clientAddr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(listenFD, &clientAddr, &len)
            if client < 0 {
                if running {
                    usleep(50_000)
                }
                continue
            }
            configureSocket(client)
            readLines(fd: client)
        }
    }

    private func configureSocket(_ fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        // 1h idle timeout — held permissions may sit for a long time
        var timeout = timeval(tv_sec: 3700, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func readLines(fd: Int32) {
        let conn = AgentBridgeConnection(fd: fd)
        var buffer = Data()
        var scratch = [UInt8](repeating: 0, count: 65_536)

        while running {
            let n = read(fd, &scratch, scratch.count)
            if n <= 0 { break }
            buffer.append(contentsOf: scratch[0..<n])

            while let idx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<idx]
                buffer.removeSubrange(buffer.startIndex...idx)
                guard !lineData.isEmpty else { continue }
                guard let line = String(data: Data(lineData), encoding: .utf8),
                      let payload = line.data(using: .utf8),
                      let message = try? JSONDecoder().decode(AgentWireMessage.self, from: payload) else {
                    continue
                }
                conn.touch()
                handle(message, from: conn)
            }
        }

        // Connection died — clean up
        handleDisconnect(conn)
        close(fd)
    }

    // MARK: Message dispatch

    private func handle(_ message: AgentWireMessage, from conn: AgentBridgeConnection) {
        switch message.kind {
        case "hello":
            handleHello(message.data, from: conn)
        case "event":
            handleEvent(message.data, from: conn)
        case "permission":
            handlePermission(message.data, from: conn)
        case "question":
            handleQuestion(message.data, from: conn)
        case "command.result":
            handleCommandResult(message.data)
        case "ping", "pong":
            break // lastSeen already updated
        default:
            break
        }
    }

    private func handleHello(_ data: AgentJSON?, from conn: AgentBridgeConnection) {
        guard let data,
              let instanceID = data["instanceID"]?.string else { return }

        let info = AgentInstanceInfo(
            id: instanceID,
            serverUrl: data["serverUrl"]?.string ?? "http://localhost:4096",
            authHeader: data["authHeader"]?.string,
            managed: data["managed"]?.bool ?? false,
            directory: data["directory"]?.string ?? "~",
            pid: data["pid"]?.number.map(Int.init),
            lastSeen: Date())

        conn.instanceID = instanceID
        let count = channelsLock.withLock {
            channels[instanceID] = conn
            instances[instanceID] = info
            return channels.count
        }

        Task { @MainActor [weak delegate] in
            delegate?.bridge(didRegisterInstance: info)
            delegate?.bridgeDidUpdateInstances(count: count)
        }
        blog("instance \(instanceID.prefix(8)) connected (dir: \(info.shortDirectory), managed: \(info.managed))")
    }

    private func handleEvent(_ data: AgentJSON?, from conn: AgentBridgeConnection) {
        guard let data,
              let instanceID = conn.instanceID,
              let parsed = AgentEvent.parse(data) else { return }
        Task { @MainActor [weak delegate] in
            delegate?.bridge(didReceiveEvent: parsed.event, sessionID: parsed.sessionID, instanceID: instanceID)
        }
    }

    private func handlePermission(_ data: AgentJSON?, from conn: AgentBridgeConnection) {
        guard let data,
              let instanceID = conn.instanceID,
              let permission = AgentPendingPermission.parse(data, instanceID: instanceID) else { return }

        registerHeldReplier(requestID: permission.id, conn: conn)
        Task { @MainActor [weak delegate] in
            delegate?.bridge(didReceivePermission: permission)
        }
    }

    private func handleQuestion(_ data: AgentJSON?, from conn: AgentBridgeConnection) {
        guard let data,
              let instanceID = conn.instanceID,
              let question = AgentPendingQuestion.parse(data, instanceID: instanceID) else { return }

        registerHeldReplier(requestID: question.id, conn: conn)
        Task { @MainActor [weak delegate] in
            delegate?.bridge(didReceiveQuestion: question)
        }
    }

    private func registerHeldReplier(requestID: String, conn: AgentBridgeConnection) {
        heldLock.lock()
        heldRepliers[requestID] = { [weak conn] directive in
            guard let conn else { return }
            _ = conn.send(directive.encode())
        }
        heldLock.unlock()
    }

    private func handleCommandResult(_ data: AgentJSON?) {
        guard let data, let id = data["id"]?.string else { return }
        ticketsLock.lock()
        let ticket = tickets.removeValue(forKey: id)
        ticketsLock.unlock()
        guard let ticket else { return }

        let result = AgentCommandResult(
            ok: data["ok"]?.bool ?? false,
            status: Int(data["status"]?.number ?? 0),
            body: data["body"],
            error: data["error"]?.string)
        ticket.continuation.resume(returning: result)
    }

    private func handleDisconnect(_ conn: AgentBridgeConnection) {
        guard let instanceID = conn.instanceID else { return }
        let (wasCurrent, count) = channelsLock.withLock {
            let wasCurrent = channels[instanceID] === conn
            if wasCurrent {
                channels.removeValue(forKey: instanceID)
                instances.removeValue(forKey: instanceID)
            }
            return (wasCurrent, channels.count)
        }

        heldLock.withLock {
            heldRepliers = heldRepliers.filter { _, _ in !wasCurrent || true }
        }

        if wasCurrent {
            Task { @MainActor [weak delegate] in
                delegate?.bridge(didLoseInstance: instanceID)
                delegate?.bridgeDidUpdateInstances(count: count)
            }
            blog("instance \(instanceID.prefix(8)) disconnected")
        }
    }

    // MARK: Public API (called from MainActor)

    /// Sends a directive answering a held permission/question request.
    func respond(to requestID: String, directive: AgentDirective) {
        heldLock.withLock {
            let replier = heldRepliers.removeValue(forKey: requestID)
            replier?(directive)
        }
    }

    /// Runs a REST call on the given OpenCode instance through its plugin
    /// channel. `path` is relative to the instance root (e.g. "/api/session".
    func command(
        on instanceID: String,
        method: String,
        path: String,
        body: AgentJSON? = nil,
        timeout: TimeInterval = 20
    ) async -> AgentCommandResult {
        let conn = channelsLock.withLock { channels[instanceID] }
        guard let conn else {
            return AgentCommandResult(ok: false, status: 0, body: nil, error: "OpenCode instance is not connected.")
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<AgentCommandResult, Never>) in
            let ticket = AgentCommandTicket(continuation: continuation)
            ticketsLock.withLock { tickets[ticket.id] = ticket }

            var payload: [String: AgentJSON] = [
                "id": .string(ticket.id),
                "method": .string(method),
                "path": .string(path),
            ]
            if let body { payload["body"] = body }

            let sent = conn.send(AgentWireOutgoing(v: 1, kind: "command", data: .object(payload)))
            if !sent {
                ticketsLock.withLock { tickets.removeValue(forKey: ticket.id) }
                continuation.resume(returning: AgentCommandResult(ok: false, status: 0, body: nil, error: "OpenCode connection lost."))
                return
            }

            // Timeout guard
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                let expired = self.ticketsLock.withLock { self.tickets.removeValue(forKey: ticket.id) }
                if let expired {
                    expired.continuation.resume(returning: AgentCommandResult(ok: false, status: 0, body: nil, error: "OpenCode did not respond in time."))
                }
            }
        }
    }

    /// Convenience: decodes the command body as a Codable type.
    func command<T: Decodable>(
        on instanceID: String,
        method: String,
        path: String,
        body: AgentJSON? = nil,
        as type: T.Type,
        timeout: TimeInterval = 20
    ) async -> T? {
        let result = await command(on: instanceID, method: method, path: path, body: body, timeout: timeout)
        guard result.ok, let body = result.body else { return nil }
        guard let data = try? JSONEncoder().encode(body) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    var connectedInstanceIDs: [String] {
        channelsLock.withLock { Array(channels.keys) }
    }

    var instanceInfos: [AgentInstanceInfo] {
        channelsLock.withLock { Array(instances.values) }
    }

    var primaryInstanceID: String? {
        channelsLock.withLock {
            instances.values.max(by: { $0.lastSeen < $1.lastSeen })?.id
        }
    }

    // MARK: Stale connections

    private func startStaleCheck() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let stale = self.channelsLock.withLock {
                self.channels.filter { Date().timeIntervalSince($0.value.lastSeen) > 120 }
            }
            for (id, conn) in stale {
                blog("dropping stale instance \(id.prefix(8))")
                shutdown(conn.fd, Int32(SHUT_RDWR))
            }
        }
        timer.resume()
        staleCheckTimer = timer
    }
}

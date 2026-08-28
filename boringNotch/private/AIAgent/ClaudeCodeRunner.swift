//
//  ClaudeCodeRunner.swift
//  boringNotch
//
//  Drives Claude Code in headless print mode for sessions the notch manages:
//  spawns `claude -p --output-format stream-json`, streams assistant text
//  and tool activity back to the view model, and can interrupt a run.
//  The session's transcript on disk remains the source of truth.
//

import Foundation
import Defaults

enum ClaudeAuthState: Equatable {
    case authenticated
    case needsAuth
}

final class ClaudeCodeRunner: @unchecked Sendable {
    enum Event {
        case assistantText(String)
        case toolUsed(name: String, detail: String?)
        case finished(reply: String?, isError: Bool, message: String?)
    }

    private var process: Process?
    private let lock = NSLock()
    private var interrupted = false

    // MARK: Binary + auth

    /// Locates the claude CLI: settings override, then PATH via `which`,
    /// then the usual install locations.
    static func resolveBinary() -> String {
        let configured = Defaults[.aiAgentClaudeBinary]
        if !configured.isEmpty, FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }
        if let p = which("claude"), !p.isEmpty, FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        let home = NSHomeDirectory()
        let candidates = [
            (home as NSString).appendingPathComponent(".local/bin/claude"),
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return ""
    }

    private static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = [
            (home as NSString).appendingPathComponent(".local/bin"),
            "/opt/homebrew/bin",
            "/usr/local/bin",
            env["PATH"],
            "/usr/bin:/bin:/usr/sbin:/sbin",
        ].compactMap { $0 }.joined(separator: ":")
        process.environment = env
        process.arguments = [name]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Best-effort auth check: OAuth account, stored credentials, or an API
    /// key in the environment.
    static func authState() -> ClaudeAuthState {
        let home = NSHomeDirectory()
        let fm = FileManager.default

        // ~/.claude.json carries the OAuth account info.
        let claudeJSON = (home as NSString).appendingPathComponent(".claude.json")
        if let data = fm.contents(atPath: claudeJSON),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["oauthAccount"] != nil {
            return .authenticated
        }

        if fm.fileExists(atPath: (home as NSString).appendingPathComponent(".claude/.credentials.json")) {
            return .authenticated
        }

        if ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?.isEmpty == false {
            return .authenticated
        }

        return .needsAuth
    }

    // MARK: Running

    /// Runs one prompt in the given session. Returns once the run finishes.
    /// Events are delivered on the main actor via `onEvent`.
    func run(
        prompt: String,
        sessionID: String,
        isNewSession: Bool,
        directory: String,
        model: String?,
        onEvent: @escaping @MainActor (Event) -> Void
    ) async {
        let binary = Self.resolveBinary()
        guard !binary.isEmpty else {
            await MainActor.run { onEvent(.finished(reply: nil, isError: true, message: "Claude Code CLI not found")) }
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)

        var arguments = ["-p", "--output-format", "stream-json", "--verbose"]
        if isNewSession {
            arguments += ["--session-id", sessionID]
        } else {
            arguments += ["--resume", sessionID]
        }
        if let model, !model.isEmpty {
            arguments += ["--model", model]
        }
        process.arguments = arguments

        let ws = directory.isEmpty ? NSHomeDirectory() : directory
        process.currentDirectoryURL = URL(fileURLWithPath: ws)

        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["HOME"] = home
        env["USER"] = NSUserName()
        env["LOGNAME"] = NSUserName()
        env["SHELL"] = "/bin/zsh"
        env["PATH"] = [
            (home as NSString).appendingPathComponent(".local/bin"),
            "/opt/homebrew/bin",
            "/usr/local/bin",
            env["PATH"],
            "/usr/bin:/bin:/usr/sbin:/sbin",
        ].compactMap { $0 }.joined(separator: ":")
        env["BORING_NOTCH_MANAGED"] = "1"
        process.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        var stderrText = ""
        let stderrGroup = DispatchGroup()
        stderrGroup.enter()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stderrGroup.leave()
            } else if let s = String(data: data, encoding: .utf8) {
                // readabilityHandler calls are serialized per handle, so a
                // plain append is race-free here.
                stderrText += s
            }
        }

        do {
            try process.run()
        } catch {
            await MainActor.run { onEvent(.finished(reply: nil, isError: true, message: "Failed to launch claude: \(error.localizedDescription)")) }
            return
        }

        lock.lock()
        self.process = process
        interrupted = false
        lock.unlock()

        // Write the prompt to stdin, then close it so the run starts.
        let promptData = Data(prompt.utf8)
        try? stdin.fileHandleForWriting.write(contentsOf: promptData)
        try? stdin.fileHandleForWriting.close()

        // Stream-parse stdout line by line on a background thread.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread { [weak self] in
                let handle = stdout.fileHandleForReading
                var buffer = Data()
                var finalReply: String?
                var finalError: String?

                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let idx = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer[buffer.startIndex..<idx]
                        buffer.removeSubrange(buffer.startIndex...idx)
                        guard !lineData.isEmpty,
                              let line = String(data: Data(lineData), encoding: .utf8),
                              let data = line.data(using: .utf8),
                              let obj = try? JSONDecoder().decode(AgentJSON.self, from: data) else { continue }

                        switch obj["type"]?.string {
                        case "assistant":
                            let blocks = obj["message"]?["content"]?.array ?? []
                            let text = blocks.filter { $0["type"]?.string == "text" }
                                .compactMap { $0["text"]?.string }
                                .joined(separator: "\n\n")
                            if !text.isEmpty {
                                let reply = text
                                Task { @MainActor in onEvent(.assistantText(reply)) }
                            }
                            for tool in blocks where tool["type"]?.string == "tool_use" {
                                let name = tool["name"]?.string ?? "tool"
                                let detail = AgentBridgeServer.describe(tool: name, input: tool["input"])
                                Task { @MainActor in onEvent(.toolUsed(name: name, detail: detail)) }
                            }
                        case "result":
                            if let result = obj["result"]?.string { finalReply = result }
                            if obj["is_error"]?.bool == true {
                                let message = obj["result"]?.string ?? "Claude Code returned an error"
                                finalError = message
                            }
                        default:
                            break
                        }
                    }
                }

                process.waitUntilExit()
                stderrGroup.wait()
                let status = process.terminationStatus
                let wasInterrupted = self?.isInterrupted() ?? false

                Task { @MainActor in
                    if wasInterrupted {
                        onEvent(.finished(reply: finalReply, isError: false, message: "Interrupted"))
                    } else if status != 0 || finalError != nil {
                        let message = finalError ?? Self.trimmedTail(stderrText) ?? "claude exited with status \(status)"
                        onEvent(.finished(reply: nil, isError: true, message: message))
                    } else {
                        onEvent(.finished(reply: finalReply, isError: false, message: nil))
                    }
                    continuation.resume()
                }
            }
        }

        lock.lock()
        self.process = nil
        lock.unlock()
    }

    func interrupt() {
        lock.lock()
        defer { lock.unlock() }
        interrupted = true
        if let process, process.isRunning {
            kill(process.processIdentifier, SIGINT)
        }
    }

    private func isInterrupted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return interrupted
    }

    private static func trimmedTail(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return String(t.suffix(400))
    }
}
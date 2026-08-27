//
//  OpenCodeServerManager.swift
//  boringNotch
//
//  Owns the lifecycle of the local opencode server and exposes the
//  connection configuration (URL, credentials, workspace) used by the client.
//

import Foundation
import Combine
import Defaults

@MainActor
final class OpenCodeServerManager: ObservableObject {
    static let shared = OpenCodeServerManager()

    @Published var isRunning: Bool = false
    @Published var lastError: String?

    var baseURL: URL {
        URL(string: Defaults[.aiAgentServerURL].trimmingCharacters(in: .whitespaces)) ?? URL(string: "http://127.0.0.1:4096")!
    }

    var workspace: String {
        let value = Defaults[.aiAgentWorkspace].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? NSHomeDirectory() : value
    }

    var username: String {
        let value = Defaults[.aiAgentServerUsername].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? "opencode" : value
    }

    var password: String {
        let value = Defaults[.aiAgentServerPassword]
        if value.isEmpty, let env = ProcessInfo.processInfo.environment["OPENCODE_SERVER_PASSWORD"] {
            return env
        }
        return value
    }

    private var process: Process?

    // MARK: - Auth / headers

    func authHeader() -> String {
        let credentials = "\(username):\(password)"
        guard let data = credentials.data(using: .utf8) else { return "" }
        return "Basic \(data.base64EncodedString())"
    }

    func workspaceHeaders() -> [String: String] {
        ["x-opencode-workspace": workspace, "x-opencode-directory": workspace]
    }

    // MARK: - Lifecycle

    /// Starts the bundled opencode server when auto-launch is enabled and the
    /// configured URL points at localhost. Otherwise just checks connectivity.
    func start() {
        guard Defaults[.aiAgentAutoLaunch] else {
            Task { await updateRunningState() }
            return
        }

        let host = baseURL.host?.lowercased() ?? ""
        guard host == "127.0.0.1" || host == "localhost" else {
            Task { await updateRunningState() }
            return
        }

        Task {
            if await healthOK() {
                await MainActor.run { self.isRunning = true }
                return
            }
            await MainActor.run { self.launchProcess() }
            await self.waitUntilHealthy()
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        isRunning = false
    }

    private func launchProcess() {
        let binary = Self.resolveBinary()
        guard FileManager.default.fileExists(atPath: binary) else {
            lastError = "opencode binary not found. Install opencode or point the server URL at a running instance."
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = [
            "serve",
            "--port", String(baseURL.port ?? 4096),
            "--hostname", baseURL.host ?? "127.0.0.1"
        ]
        var env = ProcessInfo.processInfo.environment
        if !password.isEmpty {
            env["OPENCODE_SERVER_PASSWORD"] = password
        }
        proc.environment = env
        proc.standardOutput = nil
        proc.standardError = nil

        do {
            try proc.run()
            process = proc
        } catch {
            lastError = "Failed to launch opencode: \(error.localizedDescription)"
        }
    }

    // MARK: - Health

    func healthOK() async -> Bool {
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/health"))
            request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                return http.statusCode == 200
            }
        } catch {
            // ignore, treated as not healthy
        }
        return false
    }

    private func updateRunningState() async {
        isRunning = await healthOK()
    }

    private func waitUntilHealthy() async {
        for _ in 0..<60 {
            if await healthOK() {
                await MainActor.run { self.isRunning = true }
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        await MainActor.run {
            self.isRunning = false
            self.lastError = "opencode server did not become reachable."
        }
    }

    // MARK: - Helpers

    static func resolveBinary() -> String {
        let candidates = [
            Defaults[.aiAgentServerBinary].trimmingCharacters(in: .whitespacesAndNewlines),
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
            "\(NSHomeDirectory())/.opencode/bin/opencode",
            "/usr/bin/opencode"
        ]
        for candidate in candidates where !candidate.isEmpty && FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return "opencode"
    }

    private static func runWhich() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-lc", "which opencode"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !out.isEmpty {
                    continuation.resume(returning: out)
                } else {
                    continuation.resume(returning: nil)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

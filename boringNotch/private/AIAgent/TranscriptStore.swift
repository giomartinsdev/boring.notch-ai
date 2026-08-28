//
//  TranscriptStore.swift
//  boringNotch
//
//  Reads Claude Code session transcripts from ~/.claude/projects/. Each
//  session is a JSONL file; user/assistant messages, the AI-generated
//  title, and the model are extracted from it. This is the source of truth
//  for the sessions list and the chat view.
//

import Foundation

enum TranscriptStore {
    struct Summary {
        let id: String
        var directory: String
        var title: String?
        var model: String?
        var lastPrompt: String?
        var lastReply: String?
        var updatedAt: Date
    }

    static var projectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Encodes a working directory the way Claude Code names project folders
    /// ("/Users/gio/dev" → "-Users-gio-dev").
    static func projectFolderName(for directory: String) -> String {
        directory.hasPrefix("/")
            ? directory.replacingOccurrences(of: "/", with: "-")
            : "-" + directory.replacingOccurrences(of: "/", with: "-")
    }

    // MARK: Scanning

    /// Scans all project transcripts, most recently updated first.
    static func scan(limit: Int = 40) -> [Summary] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipHiddenFiles]) else { return [] }

        var files: [(url: URL, modified: Date)] = []
        for dir in projectDirs where dir.hasDirectoryPath {
            guard let sessionFiles = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipHiddenFiles]) else { continue }
            for file in sessionFiles where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? Date.distantPast
                files.append((file, modified))
            }
        }

        files.sort { $0.modified > $1.modified }
        var summaries: [Summary] = []
        for (url, modified) in files.prefix(limit) {
            if let summary = summarize(file: url, modified: modified) {
                summaries.append(summary)
            }
        }
        return summaries
    }

    /// Extracts session metadata from a transcript file with a light-weight
    /// pass: only lines mentioning interesting keys are JSON-decoded.
    private static func summarize(file url: URL, modified: Date) -> Summary? {
        let id = url.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var directory = ""
        var title: String?
        var model: String?
        var lastPrompt: String?
        var lastReply: String?

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let l = line[...]
            if title == nil, l.contains("\"ai-title\""), let obj = decode(l) {
                title = obj["aiTitle"]?.string
                continue
            }
            if l.contains("\"cwd\""), directory.isEmpty, let obj = decode(l) {
                directory = obj["cwd"]?.string ?? ""
            }
            if l.contains("\"type\":\"user\""), let obj = decode(l) {
                if let prompt = userText(from: obj), !prompt.isEmpty {
                    lastPrompt = prompt
                }
                continue
            }
            if l.contains("\"type\":\"assistant\""), let obj = decode(l) {
                if let m = obj["message"]?["model"]?.string { model = m }
                if let reply = assistantText(from: obj), !reply.isEmpty {
                    lastReply = reply
                }
            }
        }

        // Skip sessions that contain no conversation at all.
        guard lastPrompt != nil || lastReply != nil else { return nil }

        return Summary(
            id: id,
            directory: directory,
            title: title,
            model: model,
            lastPrompt: lastPrompt,
            lastReply: lastReply,
            updatedAt: modified)
    }

    // MARK: Messages

    /// Full transcript parse for the chat view, oldest first.
    static func messages(sessionID: String, directory: String?) -> [AgentChatMessage] {
        guard let url = transcriptURL(for: sessionID, directory: directory),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }

        var messages: [AgentChatMessage] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let l = line[...]
            if l.contains("\"type\":\"user\""), let obj = decode(l) {
                if let prompt = userText(from: obj), !prompt.isEmpty {
                    messages.append(AgentChatMessage(id: obj["uuid"]?.string ?? UUID().uuidString,
                                                     role: .user, text: prompt))
                }
            } else if l.contains("\"type\":\"assistant\""), let obj = decode(l) {
                if let reply = assistantText(from: obj), !reply.isEmpty {
                    messages.append(AgentChatMessage(id: obj["uuid"]?.string ?? UUID().uuidString,
                                                     role: .assistant, text: reply))
                }
            }
        }
        return messages
    }

    /// Current session model, from the most recent assistant entry.
    static func currentModel(sessionID: String, directory: String?) -> String? {
        guard let url = transcriptURL(for: sessionID, directory: directory),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains("\"type\":\"assistant\""), let obj = decode(line[...]),
                  let model = obj["message"]?["model"]?.string else { continue }
            return model
        }
        return nil
    }

    static func transcriptURL(for sessionID: String, directory: String?) -> URL? {
        let fm = FileManager.default
        if let directory, !directory.isEmpty {
            let candidate = projectsRoot
                .appendingPathComponent(projectFolderName(for: directory))
                .appendingPathComponent("\(sessionID).jsonl")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        // Search all project folders for the session file.
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil, options: [.skipHiddenFiles]) else {
            return nil
        }
        for dir in projectDirs {
            let candidate = dir.appendingPathComponent("\(sessionID).jsonl")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: Line parsing

    private static func decode<S: StringProtocol>(_ line: S) -> AgentJSON? {
        guard let data = String(line).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentJSON.self, from: data)
    }

    /// Extracts the displayable text of a user entry. Tool results and
    /// command metadata are not shown as chat bubbles.
    private static func userText(from entry: AgentJSON) -> String? {
        guard entry["isSidechain"]?.bool != true,
              entry["isMeta"]?.bool != true else { return nil }
        guard let content = entry["message"]?["content"] else { return nil }
        if let text = content.string {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            // Skip local command echoes like <command-name>/model</command-name>
            if trimmed.hasPrefix("<command-name>") || trimmed.hasPrefix("<local-command") {
                return nil
            }
            return stripSystemReminder(trimmed)
        }
        guard let blocks = content.array else { return nil }
        let texts = blocks
            .filter { $0["type"]?.string == "text" }
            .compactMap { $0["text"]?.string }
            .joined(separator: "\n\n")
        let trimmed = texts.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : stripSystemReminder(trimmed)
    }

    /// Extracts the assistant's visible text (ignoring thinking and tool
    /// use blocks).
    private static func assistantText(from entry: AgentJSON) -> String? {
        guard let blocks = entry["message"]?["content"]?.array else { return nil }
        let texts = blocks
            .filter { $0["type"]?.string == "text" }
            .compactMap { $0["text"]?.string }
            .joined(separator: "\n\n")
        let trimmed = texts.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stripSystemReminder(_ text: String) -> String {
        guard let range = text.range(of: "<system-reminder>") else { return text }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
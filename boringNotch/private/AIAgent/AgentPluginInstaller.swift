//
//  AgentPluginInstaller.swift
//  boringNotch
//
//  Installs the bridge plugin into ~/.config/opencode/plugins/ so every
//  OpenCode instance (TUI, run) auto-loads it and connects to the notch.
//

import Foundation
import AppKit

enum AgentPluginInstaller {
    static var pluginsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode/plugins", isDirectory: true)
    }

    static var pluginFileURL: URL {
        pluginsDirectory.appendingPathComponent(AgentPluginSource.fileName)
    }

    static func isInstalled() -> Bool {
        guard let current = try? String(contentsOf: pluginFileURL, encoding: .utf8) else {
            return false
        }
        return current == AgentPluginSource.source
    }

    @discardableResult
    static func install() -> Bool {
        do {
            try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
            try AgentPluginSource.source.write(to: pluginFileURL, atomically: true, encoding: .utf8)
            NSLog("[Agent] plugin installed at \(pluginFileURL.path)")
            return true
        } catch {
            NSLog("[Agent] plugin install failed: \(error)")
            return false
        }
    }

    static func uninstall() {
        try? FileManager.default.removeItem(at: pluginFileURL)
    }

    /// Installs the plugin if missing or outdated. Safe to call on every launch.
    static func ensureInstalled() {
        if !isInstalled() {
            install()
        }
    }
}

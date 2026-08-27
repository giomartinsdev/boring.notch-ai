//
//  AIAgentSettingsView.swift
//  boringNotch
//
//  Settings pane for the OpenCode agent integration. Matches boring.notch's
//  SettingsView style with grouped sections and clean visual hierarchy.
//

import SwiftUI
import Defaults
import LaunchAtLogin

struct AIAgentSettingsView: View {
    @Default(.aiAgentEnabled) var enabled
    @Default(.aiAgentAutoOpen) var autoOpen
    @Default(.aiAgentNotifyOnDone) var notifyOnDone
    @Default(.aiAgentServerURL) var serverURL
    @Default(.aiAgentServerUsername) var username
    @Default(.aiAgentServerPassword) var password
    @Default(.aiAgentModel) var defaultModel
    @ObservedObject private var vm = AIAgentViewModel.shared

    var body: some View {
        Form {
            // Enable section
            Section {
                Toggle("Enable Agent tab", isOn: $enabled)
                    .tint(.effectiveAccent)
                Text("Adds an Agent tab to the notch and a desktop window for your opencode sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Connection status
            Section {
                HStack {
                    Circle()
                        .fill(vm.connected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(vm.connected ? "Connected to OpenCode" : "Waiting for OpenCode…")
                        .font(.callout)
                        .foregroundStyle(vm.connected ? .primary : .secondary)
                    Spacer()
                    if !vm.connected {
                        Button("Restart Bridge") { AIAgentViewModel.shared.restart() }
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)

                if vm.connected, let info = vm.instances.first {
                    Text("Bridge: \(info.shortDirectory) · \(info.managed ? "managed" : "discovered")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Auto-open notch for approvals & done", isOn: $autoOpen)
                    .tint(.effectiveAccent)
                Toggle("Notify when agent finishes a task", isOn: $notifyOnDone)
                    .tint(.effectiveAccent)

                Button("Install / Update OpenCode Plugin") {
                    AgentPluginInstaller.install()
                }
                .controlSize(.small)

                if AgentPluginInstaller.isInstalled() {
                    Text("Plugin installed at ~/.config/opencode/plugins/boring-notch.js")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Plugin not installed — click above to install")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            // Default model
            Section("Default Model") {
                Picker("Model", selection: $defaultModel) {
                    Text("Default (opencode)").tag("")
                    ForEach(vm.availableModels) { m in
                        Text("\(m.name ?? m.id) (\(m.providerID))").tag("\(m.providerID)/\(m.id)")
                    }
                }
                .onAppear { Task { await AIAgentViewModel.shared.fetchModels(instanceID: AIAgentViewModel.shared.bridge.primaryInstanceID ?? "") } }

                if !defaultModel.isEmpty {
                    Text("Used when creating new sessions from the notch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Advanced
            Section("Advanced") {
                TextField("Server URL (auto-discovered)", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
                    .help("Auto-discovered from the OpenCode plugin bridge")

                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)

                SecureField("Password (optional)", text: $password)
                    .textFieldStyle(.roundedBorder)

                Text("Credentials are stored locally and sent only to your local OpenCode server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Actions
            Section {
                Button("Open Agent Window") {
                    AIAgentWindowController.shared.showWindow()
                }
                Button("Refresh Models") {
                    Task { await AIAgentViewModel.shared.fetchModels(instanceID: AIAgentViewModel.shared.bridge.primaryInstanceID ?? "") }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
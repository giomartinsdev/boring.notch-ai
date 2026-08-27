//
//  AIAgentSettingsView.swift
//  boringNotch
//
//  Settings pane for the opencode agent integration.
//

import SwiftUI
import Defaults

struct AIAgentSettingsView: View {
    @Default(.aiAgentEnabled) var enabled
    @Default(.aiAgentAutoLaunch) var autoLaunch
    @Default(.aiAgentServerURL) var serverURL
    @Default(.aiAgentServerUsername) var username
    @Default(.aiAgentServerPassword) var password
    @Default(.aiAgentServerBinary) var binary
    @Default(.aiAgentWorkspace) var workspace
    @Default(.aiAgentModel) var model
    @ObservedObject private var vm = AIAgentViewModel.shared

    var body: some View {
        Form {
            Section {
                Toggle("Enable AI Agent panel", isOn: $enabled)
                    .tint(.effectiveAccent)
                Text("Adds an “Agent” tab to the notch and a desktop control window for your opencode agent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Server") {
                Toggle("Auto-launch opencode when Boring Notch opens", isOn: $autoLaunch)
                    .tint(.effectiveAccent)
                TextField("Server URL", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Workspace path", text: $workspace)
                    .textFieldStyle(.roundedBorder)
                    .help("Project directory the agent operates on, e.g. /Users/you/projects/myapp")
                Picker("Model", selection: $model) {
                    Text("Default (opencode)").tag("")
                    ForEach(vm.availableModels) { option in
                        Text(option.display).tag(option.ref)
                    }
                }
                .onAppear { Task { await vm.fetchModels() } }
            }

            Section("Authentication") {
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                TextField("Custom opencode binary path (optional)", text: $binary)
                    .textFieldStyle(.roundedBorder)
            }

            Section {
                Button("Open control window") {
                    AIAgentViewModel.shared.activate()
                    AIAgentWindowController.shared.showWindow()
                }
                Button("Refresh models") {
                    Task { await vm.fetchModels() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

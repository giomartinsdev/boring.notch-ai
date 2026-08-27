//
//  AIAgentPanel.swift
//  boringNotch
//
//  Compact control surface shown inside the notch when the "Agent" tab is
//  selected. Pair it with AIAgentFullView for the full desktop window.
//

import SwiftUI
import Defaults

struct AIAgentPanel: View {
    @ObservedObject private var vm = AIAgentViewModel.shared
    @State private var questionAnswer: String = ""

    private var statusColor: Color {
        switch vm.connectionState {
        case .connected: return .green
        case .connecting: return .yellow
        case .error: return .red
        case .disconnected: return .gray
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            header

            if vm.sessions.isEmpty {
                Spacer()
                Button(action: { Task { await vm.createSession() } }) {
                    Label("New session", systemImage: "plus.bubble")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            } else {
                if !vm.pendingPermissions.isEmpty {
                    permissionsBanner
                }
                messagesList
                promptBar
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { vm.ensureConnected() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text("AI Agent")
                .font(.caption.weight(.semibold))
            Text(vm.agentStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: { AIAgentWindowController.shared.showWindow() }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help("Open full agent window")
            Menu {
                ForEach(vm.sessions) { session in
                    Button(session.displayName) { vm.selectSession(session.id) }
                }
                Divider()
                Button("New session") { Task { await vm.createSession() } }
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .buttonStyle(.plain)
        }
    }

    private var permissionsBanner: some View {
        ForEach(vm.pendingPermissions) { request in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    Text(request.summary)
                        .font(.caption.weight(.medium))
                        .lineLimit(2)
                }
                if let input = request.input?.string, !input.isEmpty {
                    Text(input)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack {
                    Button("Approve") { vm.approve(request.id) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Deny") { vm.deny(request.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
        }
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(vm.displayMessages.suffix(30)) { message in
                        HStack {
                            if message.role == .user { Spacer() }
                            Text(message.text)
                                .font(.caption)
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(message.role == .user ? Color.accentColor.opacity(0.25) : Color(nsColor: .secondarySystemFill))
                                )
                            if message.role == .assistant { Spacer() }
                        }
                        .id(message.id)
                    }
                    if vm.isWorking {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 4)
            }
            .onChange(of: vm.displayMessages.count) {
                if let last = vm.displayMessages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(maxHeight: 96)
    }

    private var promptBar: some View {
        HStack(spacing: 6) {
            TextField("Ask your agent…", text: $vm.promptText, onCommit: { vm.sendPrompt() })
                .textFieldStyle(.plain)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
            Button(action: { vm.sendPrompt() }) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.plain)
            .disabled(vm.promptText.trimmingCharacters(in: .whitespaces).isEmpty)
            Button(action: { vm.interrupt() }) {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.plain)
            .help("Interrupt")
        }
    }
}

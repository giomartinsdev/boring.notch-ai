//
//  AIAgentFullView.swift
//  boringNotch
//
//  Full desktop window for driving the opencode agent: session switcher,
//  live transcript, prompt input, and inline approve/deny of permission and
//  question prompts — the VibeIsland-style cockpit.
//

import SwiftUI
import Defaults

struct AIAgentFullView: View {
    @ObservedObject private var vm = AIAgentViewModel.shared
    @State private var draft: String = ""

    var body: some View {
        HStack(spacing: 0) {
            sessionSidebar
                .frame(width: 200)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            VStack(spacing: 0) {
                transcript
                Divider()
                promptBar
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private var sessionSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sessions")
                    .font(.headline)
                Spacer()
                Button(action: { Task { await vm.createSession() } }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            Divider()

            List(vm.sessions, selection: Binding(
                get: { vm.selectedSessionID },
                set: { if let id = $0 { vm.selectSession(id) } }
            )) { session in
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName).font(.callout.weight(.medium))
                    if let model = session.model {
                        Text("\(model.id) · \(model.providerID)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(vm.displayMessages) { message in
                        HStack {
                            if message.role == .user { Spacer() }
                            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
                                Text(message.role == .user ? "You" : "Agent")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(message.text)
                                    .textSelection(.enabled)
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(message.role == .user ? Color.accentColor.opacity(0.22) : Color(nsColor: .secondarySystemFill))
                                    )
                            }
                            if message.role == .assistant { Spacer() }
                        }
                        .id(message.id)
                    }

                    ForEach(vm.pendingPermissions) { request in
                        permissionCard(request)
                    }

                    ForEach(vm.pendingQuestions) { request in
                        QuestionCard(request: request)
                    }

                    if vm.isWorking {
                        HStack {
                            ProgressView().scaleEffect(0.7)
                            Text("Agent is working…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
            }
            .onChange(of: vm.displayMessages.count + vm.pendingPermissions.count + vm.pendingQuestions.count) {
                if let last = vm.displayMessages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func permissionCard(_ request: PermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(request.summary, systemImage: "hand.raised.fill")
                .font(.callout.weight(.medium))
            if let input = request.input?.string, !input.isEmpty {
                Text(input)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Approve") { vm.approve(request.id) }
                    .buttonStyle(.borderedProminent)
                Button("Deny") { vm.deny(request.id) }
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
    }

    private struct QuestionCard: View {
        let request: QuestionRequest
        @State private var answer: String = ""
        @ObservedObject private var vm = AIAgentViewModel.shared

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Label("Question", systemImage: "questionmark.circle.fill")
                    .font(.callout.weight(.medium))
                if let question = request.question, !question.isEmpty {
                    Text(question).font(.caption)
                }
                HStack(spacing: 6) {
                    TextField("Type your answer…", text: $answer, onCommit: { vm.answerQuestion(request.id, text: answer) })
                        .textFieldStyle(.roundedBorder)
                    Button("Send") { vm.answerQuestion(request.id, text: answer) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.12)))
        }
    }

    private var promptBar: some View {
        HStack(spacing: 8) {
            TextField("Send a prompt to your agent…", text: $draft, onCommit: send)
                .textFieldStyle(.roundedBorder)
            Button(action: send) {
                Image(systemName: "paperplane.fill")
            }
            Button(action: { vm.interrupt() }) {
                Image(systemName: "stop.fill")
            }
            .help("Interrupt")
        }
        .padding(10)
    }

    private func send() {
        let text = draft
        draft = ""
        vm.sendPrompt(text)
    }
}

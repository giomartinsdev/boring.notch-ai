//
//  AgentNotificationCard.swift
//  boringNotch
//
//  The interactive surfaces shown when the notch opens itself: permission
//  approvals, agent questions with option lists, and "done" replies with a
//  quick-reply box. Rendered in the expanded notch without requiring the
//  user to enter the AI tab.
//

import SwiftUI
import Defaults

// MARK: - Root surface (picks the top-priority card)

struct AgentNotificationSurface: View {
    @ObservedObject private var vm = AIAgentViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            if let question = vm.activeQuestion {
                AgentQuestionCard(question: question)
            } else if let permission = vm.activePermission {
                AgentPermissionCard(permission: permission)
            } else if let done = vm.activeDoneCard {
                AgentDoneCardView(card: done)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared card chrome

private struct AgentCardChrome<Content: View>: View {
    let tint: Color
    let icon: String
    let title: String
    let subtitle: String
    var onDismiss: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Icon column
            ZStack {
                Circle()
                    .fill(tint.opacity(0.14))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .padding(.top, 2)

            // Body
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AgentPalette.paper)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(AgentPalette.paperSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AgentPalette.paperFaint)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Dismiss (the request stays in the Agent tab)")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

// MARK: - Permission card

struct AgentPermissionCard: View {
    @ObservedObject private var vm = AIAgentViewModel.shared
    let permission: AgentPendingPermission

    var body: some View {
        AgentCardChrome(
            tint: .orange,
            icon: "hand.raised.fill",
            title: "OpenCode needs permission",
            subtitle: subtitleText,
            onDismiss: { vm.dismissCard(permission.id) }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if !permission.command.isEmpty {
                    Text(permission.command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AgentPalette.paper.opacity(0.85))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.05))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
                        )
                }

                HStack(spacing: 8) {
                    Button("Approve") {
                        vm.approve(permission: permission)
                    }
                    .buttonStyle(AgentPrimaryButtonStyle(tint: AgentPalette.completed))

                    Button("Always") {
                        vm.approve(permission: permission, always: true)
                    }
                    .buttonStyle(AgentSecondaryButtonStyle())

                    Button("Deny") {
                        vm.deny(permission: permission)
                    }
                    .buttonStyle(AgentSecondaryButtonStyle(tint: AgentPalette.waitingApproval))
                }
            }
        }
    }

    private var subtitleText: String {
        var parts = [permission.label]
        if let dir = permission.directory, !dir.isEmpty {
            parts.append((dir as NSString).lastPathComponent)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Question card

struct AgentQuestionCard: View {
    @ObservedObject private var vm = AIAgentViewModel.shared
    let question: AgentPendingQuestion
    @State private var selected: [String: [String]] = [:]
    @State private var customText = ""
    @State private var submitting = false

    var body: some View {
        AgentCardChrome(
            tint: AgentPalette.waitingAnswer,
            icon: "questionmark.bubble.fill",
            title: titleText,
            subtitle: subtitleText,
            onDismiss: { vm.dismissCard(question.id) }
        ) {
            VStack(alignment: .leading, spacing: 7) {
                if question.questions.count == 1, let q = question.questions.first {
                    questionBody(q)
                } else {
                    Text("Multiple questions — answer in the Agent tab or the terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(AgentPalette.paperSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private func questionBody(_ q: AgentQuestionItem) -> some View {
        if q.options.count <= 3 {
            HStack(spacing: 8) {
                ForEach(q.options) { option in
                    Button {
                        submit(answers: [[option.label]])
                    } label: {
                        VStack(spacing: 2) {
                            Text(option.label)
                                .font(.system(size: 11.5, weight: .medium))
                            if !option.detail.isEmpty {
                                Text(option.detail)
                                    .font(.system(size: 9.5))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        .foregroundStyle(AgentPalette.paper)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.white.opacity(0.07))
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(submitting)
                }
                if q.custom {
                    customField
                }
            }
        } else {
            // Many options — compact list
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(q.options) { option in
                        Button {
                            submit(answers: [[option.label]])
                        } label: {
                            HStack {
                                AgentStateDot(color: AgentPalette.paperFaint, pulsing: false, size: 5)
                                Text(option.label)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(AgentPalette.paper)
                                Spacer()
                                if !option.detail.isEmpty {
                                    Text(option.detail)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(AgentPalette.paperFaint)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.white.opacity(0.05))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(submitting)
                    }
                }
            }
            .frame(maxHeight: 74)
        }
    }

    private var customField: some View {
        HStack(spacing: 6) {
            TextField("Type…", text: $customText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(AgentPalette.paper)
                .onSubmit { submitCustom() }
            Button {
                submitCustom()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(customText.isEmpty ? AgentPalette.paperFaint : AgentPalette.paper)
            }
            .buttonStyle(.plain)
            .disabled(customText.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .frame(maxWidth: 150)
    }

    private func submitCustom() {
        let text = customText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        submit(answers: [[text]])
    }

    private func submit(answers: [[String]]) {
        guard !submitting else { return }
        submitting = true
        vm.answer(question: question, answers: answers)
    }

    private var titleText: String {
        question.questions.first?.header.isEmpty == false
            ? question.questions.first!.header
            : (question.questions.first?.question ?? "OpenCode asks")
    }

    private var subtitleText: String {
        let q = question.questions.first
        if question.questions.count > 1 {
            return "\(question.questions.count) questions · \(dirName)"
        }
        if let q, q.header.isEmpty == false {
            return q.question
        }
        return dirName
    }

    private var dirName: String {
        question.directory.map { ($0 as NSString).lastPathComponent } ?? "opencode"
    }
}

// MARK: - Done card

struct AgentDoneCardView: View {
    @ObservedObject private var vm = AIAgentViewModel.shared
    let card: AgentDoneCard
    @State private var replyText = ""
    @FocusState private var replyFocused: Bool

    var body: some View {
        AgentCardChrome(
            tint: AgentPalette.completed,
            icon: "checkmark.circle.fill",
            title: card.title,
            subtitle: "finished · tap to reply",
            onDismiss: { vm.dismissOldestDoneCard() }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(card.reply)
                    .font(.system(size: 11.5))
                    .foregroundStyle(AgentPalette.paper.opacity(0.9))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.045))
                    )

                HStack(spacing: 6) {
                    Button {
                        openInAgentTab()
                    } label: {
                        Text("Open")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AgentPalette.paperSecondary)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    quickReply
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { openInAgentTab() }
    }

    private var quickReply: some View {
        HStack(spacing: 6) {
            TextField("Quick reply…", text: $replyText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(AgentPalette.paper)
                .focused($replyFocused)
                .onSubmit { sendReply() }
            Button {
                sendReply()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(replyText.isEmpty ? AgentPalette.paperFaint : AgentPalette.paper)
            }
            .buttonStyle(.plain)
            .disabled(replyText.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 210)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(replyFocused ? Color.white.opacity(0.18) : Color.white.opacity(0.05), lineWidth: 1))
        )
    }

    private func sendReply() {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        replyText = ""
        vm.dismissOldestDoneCard()
        Task {
            vm.openChat(sessionID: card.sessionID)
            await vm.sendPrompt(text)
        }
    }

    private func openInAgentTab() {
        BoringViewCoordinator.shared.currentView = .agent
        vm.openChat(sessionID: card.sessionID)
        vm.dismissOldestDoneCard()
    }
}

// MARK: - Closed-notch compact indicator

/// Small amber indicator shown in the closed notch while an approval is pending.
struct AgentClosedIndicator: View {
    @ObservedObject private var vm = AIAgentViewModel.shared

    var body: some View {
        HStack(spacing: 6) {
            AgentStateDot(color: AgentPalette.waiting, pulsing: true, size: 7)
            Image(systemName: "brain.head.profile")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AgentPalette.paper.opacity(0.85))
            Text("you")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(AgentPalette.paperFaint)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(AgentPalette.waiting.opacity(0.16))
                .overlay(Capsule().strokeBorder(AgentPalette.waiting.opacity(0.35), lineWidth: 1))
        )
        .onTapGesture {
            AgentNotificationWindowController.shared.showIfNeeded()
        }
        .help("OpenCode is waiting for you")
    }
}

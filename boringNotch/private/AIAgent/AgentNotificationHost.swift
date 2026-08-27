//
//  AgentNotificationHost.swift
//  boringNotch
//
//  A lightweight host view that observes the agent view model and
//  conditionally displays the notification surface. Isolated from
//  ContentView's complex body to avoid ViewBuilder parser issues.
//

import SwiftUI

struct AgentNotificationHost: View {
    @ObservedObject private var vm = AIAgentViewModel.shared

    var body: some View {
        if vm.hasPendingApproval || vm.activeDoneCard != nil {
            AgentNotificationSurface()
                .transition(.opacity.combined(with: .move(edge: .top)))
                .zIndex(2)
        }
    }
}
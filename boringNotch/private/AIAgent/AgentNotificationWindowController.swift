//
//  AgentNotificationWindowController.swift
//  boringNotch
//
//  Manages a floating panel that displays agent notifications (permissions,
//  questions, done cards) over the notch area. Completely separate from
//  ContentView to avoid ViewBuilder parser complexity.
//

import AppKit
import SwiftUI
import Defaults
import Combine

final class AgentNotificationWindowController: NSWindowController {
    static let shared = AgentNotificationWindowController()

    private var hostingController: NSHostingController<AgentNotificationSurface>?
    private var statusObserver: AnyCancellable?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 190),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        setupWindow()
        observeViewModel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWindow() {
        guard let window else { return }
        window.title = "Boring Notch Agent Notifications"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.managed, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = false

        let hosting = NSHostingController(rootView: AgentNotificationSurface())
        self.hostingController = hosting
        window.contentView = hosting.view
    }

    private func observeViewModel() {
        let vm = AIAgentViewModel.shared
        statusObserver = vm.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateVisibility()
            }
        }
    }

    private func updateVisibility() {
        let vm = AIAgentViewModel.shared
        let shouldShow = vm.hasPendingApproval || vm.activeDoneCard != nil

        guard let window = window else { return }

        if shouldShow && !window.isVisible {
            positionWindow()
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else if !shouldShow && window.isVisible {
            window.orderOut(nil)
        }
    }

    private func positionWindow() {
        guard let window = window,
              let screen = NSScreen.main else { return }

        let screenFrame = screen.frame
        let notchWidth: CGFloat = 640
        let notchHeight: CGFloat = 190

        window.setFrameOrigin(NSPoint(
            x: screenFrame.origin.x + (screenFrame.width / 2) - notchWidth / 2,
            y: screenFrame.origin.y + screenFrame.height - 190
        ))
    }

    func showForDuration(_ duration: TimeInterval) {
        updateVisibility()
        if duration > 0 {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                self?.updateVisibility()
            }
        }
    }
}

extension AgentNotificationWindowController {
    static func showIfNeeded() {
        shared.updateVisibility()
    }

    static func showForDuration(_ duration: TimeInterval) {
        shared.showForDuration(duration)
    }
}
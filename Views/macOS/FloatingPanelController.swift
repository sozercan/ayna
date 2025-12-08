//
//  FloatingPanelController.swift
//  ayna
//
//  Manages the Spotlight-style floating command bar.
//

#if os(macOS)
    import AppKit
    import SwiftUI

    /// A custom panel that can always become key window for text input
    final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    /// Controller for managing the Spotlight-style floating command bar.
    @MainActor
    final class FloatingPanelController: NSObject, ObservableObject {
        /// Shared instance
        static let shared = FloatingPanelController()

        /// The floating panel window
        private var panel: KeyablePanel?

        /// The hosting view for SwiftUI content
        private var hostingView: NSHostingView<AnyView>?

        /// Whether the panel is currently visible
        @Published private(set) var isVisible: Bool = false

        /// Callback when user submits a question
        var onSubmit: ((String, AppContentResult?) -> Void)?

        override private init() {
            super.init()
        }

        // MARK: - Panel Management

        /// Shows the Spotlight-style panel centered on screen.
        /// - Parameter conversationManager: The conversation manager for handling submissions
        func show(conversationManager: ConversationManager) {
            // Create or update the panel
            if panel == nil {
                createPanel()
            }

            // Update the content view
            updateContentView(conversationManager: conversationManager)

            // Position centered on screen
            positionPanelCentered()

            // Show with animation
            panel?.alphaValue = 0
            panel?.setFrame(
                NSRect(
                    x: panel?.frame.origin.x ?? 0,
                    y: panel?.frame.origin.y ?? 0,
                    width: 600,
                    height: 88 // Initial height for quick chat
                ),
                display: true
            )

            // Make key and bring to front
            panel?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            // Ensure the panel becomes first responder
            panel?.makeFirstResponder(panel?.contentView)

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel?.animator().alphaValue = 1
            }

            isVisible = true

            DiagnosticsLogger.log(
                .workWithApps,
                level: .info,
                message: "Spotlight panel shown"
            )
        }

        /// Hides the floating panel.
        func hide() {
            guard let panel, isVisible else { return }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.panel?.orderOut(nil)
                    self?.isVisible = false
                }
            }

            DiagnosticsLogger.log(
                .workWithApps,
                level: .info,
                message: "Spotlight panel hidden"
            )
        }

        /// Toggles the panel visibility.
        func toggle(conversationManager: ConversationManager) {
            if isVisible {
                hide()
            } else {
                show(conversationManager: conversationManager)
            }
        }

        // MARK: - Panel Creation

        /// Creates the Spotlight-style panel window
        private func createPanel() {
            // Use .titled to allow key window status, but hide the title bar
            let panel = KeyablePanel(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 88),
                styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )

            // Configure panel appearance - Spotlight style
            panel.level = .floating
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.isMovableByWindowBackground = false
            panel.hidesOnDeactivate = false // Don't hide when clicking elsewhere
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false // Shadow handled by SwiftUI

            // CRITICAL: Allow panel to become key window for text input
            panel.becomesKeyOnlyIfNeeded = false

            // Set delegate
            panel.delegate = self

            self.panel = panel

            DiagnosticsLogger.log(
                .workWithApps,
                level: .info,
                message: "Spotlight panel created"
            )
        }

        /// Updates the SwiftUI content view
        private func updateContentView(conversationManager: ConversationManager) {
            guard let panel else { return }

            let spotlightView = SpotlightInputView(
                onSubmit: { [weak self] question, contentResult in
                    self?.handleSubmit(question: question, contentResult: contentResult)
                },
                onDismiss: { [weak self] in
                    self?.hide()
                }
            )
            .environmentObject(conversationManager)

            let hostingView = NSHostingView(rootView: AnyView(spotlightView))
            hostingView.frame = panel.contentView?.bounds ?? .zero
            hostingView.autoresizingMask = [.width, .height]

            panel.contentView = hostingView
            self.hostingView = hostingView
        }

        // MARK: - Positioning

        /// Positions the panel centered horizontally, 20% from top
        private func positionPanelCentered() {
            guard let panel, let screen = NSScreen.main else { return }

            let screenFrame = screen.visibleFrame
            let panelWidth: CGFloat = 600

            // Center horizontally
            let posX = screenFrame.midX - panelWidth / 2

            // 20% from top (80% from bottom in screen coordinates)
            let posY = screenFrame.minY + screenFrame.height * 0.7

            panel.setFrameOrigin(NSPoint(x: posX, y: posY))
        }

        // MARK: - Event Handling

        /// Handles question submission
        private func handleSubmit(question: String, contentResult: AppContentResult?) {
            onSubmit?(question, contentResult)
            hide()
        }

        // MARK: - Keyboard Handling

        /// Sets up escape key handler to dismiss
        func setupKeyboardHandling() {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, isVisible else { return event }

                // Escape key dismisses
                if event.keyCode == 53 { // Escape
                    hide()
                    return nil
                }

                return event
            }
        }
    }

    // MARK: - Panel Delegate

    extension FloatingPanelController: NSWindowDelegate {
        func windowDidResignKey(_: Notification) {
            // Hide when losing focus (like Spotlight)
            hide()
        }

        func windowWillClose(_: Notification) {
            isVisible = false
        }
    }
#endif

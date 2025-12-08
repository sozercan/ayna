//
//  FloatingPanelController.swift
//  ayna
//
//  Manages the floating input panel window for "Work with Apps".
//

#if os(macOS)
    import AppKit
    import SwiftUI

    /// Controller for managing the floating quick input panel.
    @MainActor
    final class FloatingPanelController: NSObject, ObservableObject {
        /// Shared instance
        static let shared = FloatingPanelController()

        /// The floating panel window
        private var panel: NSPanel?

        /// The hosting view for SwiftUI content
        private var hostingView: NSHostingView<AnyView>?

        /// Currently displayed content result
        @Published private(set) var currentContentResult: AppContentResult?

        /// Whether the panel is currently visible
        @Published private(set) var isVisible: Bool = false

        /// Callback when user submits a question
        var onSubmit: ((String, AppContentResult?) -> Void)?

        /// Callback when user wants to open main window
        var onOpenMainWindow: ((String, AppContentResult?) -> Void)?

        override private init() {
            super.init()
        }

        // MARK: - Panel Management

        /// Shows the floating panel near the mouse cursor.
        /// - Parameters:
        ///   - content: The extracted content result to display
        ///   - conversationManager: The conversation manager for handling submissions
        func show(with content: AppContentResult, conversationManager: ConversationManager) {
            currentContentResult = content

            // Create or update the panel
            if panel == nil {
                createPanel()
            }

            // Update the content view
            updateContentView(conversationManager: conversationManager)

            // Position near mouse
            positionPanelNearMouse()

            // Show with animation
            panel?.alphaValue = 0
            panel?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel?.animator().alphaValue = 1
            }

            isVisible = true

            DiagnosticsLogger.log(
                .workWithApps,
                level: .info,
                message: "Floating panel shown"
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
                    self?.currentContentResult = nil
                }
            }

            DiagnosticsLogger.log(
                .workWithApps,
                level: .info,
                message: "Floating panel hidden"
            )
        }

        /// Toggles the panel visibility.
        func toggle(with content: AppContentResult, conversationManager: ConversationManager) {
            if isVisible {
                hide()
            } else {
                show(with: content, conversationManager: conversationManager)
            }
        }

        // MARK: - Panel Creation

        /// Creates the floating panel window
        private func createPanel() {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 320),
                styleMask: [
                    .titled,
                    .closable,
                    .fullSizeContentView,
                    .nonactivatingPanel,
                    .hudWindow
                ],
                backing: .buffered,
                defer: false
            )

            // Configure panel appearance
            panel.level = .floating
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true

            // Allow first responder for text input
            panel.becomesKeyOnlyIfNeeded = false

            self.panel = panel

            DiagnosticsLogger.log(
                .workWithApps,
                level: .info,
                message: "Floating panel created"
            )
        }

        /// Updates the SwiftUI content view
        private func updateContentView(conversationManager: ConversationManager) {
            guard let panel else { return }

            let quickInputView = QuickInputView(
                contentResult: currentContentResult ?? .noContentAvailable,
                onSubmit: { [weak self] question in
                    self?.handleSubmit(question: question)
                },
                onDismiss: { [weak self] in
                    self?.hide()
                },
                onOpenMainWindow: { [weak self] question in
                    self?.handleOpenMainWindow(question: question)
                },
                onRequestPermission: {
                    AccessibilityService.shared.openAccessibilityPreferences()
                }
            )
            .environmentObject(conversationManager)

            let hostingView = NSHostingView(rootView: AnyView(quickInputView))
            hostingView.frame = panel.contentView?.bounds ?? .zero
            hostingView.autoresizingMask = [.width, .height]

            panel.contentView = hostingView
            self.hostingView = hostingView
        }

        // MARK: - Positioning

        /// Positions the panel near the mouse cursor
        private func positionPanelNearMouse() {
            guard let panel, let screen = NSScreen.main else { return }

            let mouseLocation = NSEvent.mouseLocation
            let panelSize = panel.frame.size
            let screenFrame = screen.visibleFrame

            // Calculate position (offset from mouse)
            var posX = mouseLocation.x - panelSize.width / 2
            var posY = mouseLocation.y - panelSize.height - 20 // Below cursor

            // Ensure panel stays within screen bounds
            posX = max(screenFrame.minX + 10, min(posX, screenFrame.maxX - panelSize.width - 10))
            posY = max(screenFrame.minY + 10, min(posY, screenFrame.maxY - panelSize.height - 10))

            // If panel would be below screen, show above cursor instead
            if posY < screenFrame.minY + 10 {
                posY = mouseLocation.y + 20
            }

            panel.setFrameOrigin(NSPoint(x: posX, y: posY))
        }

        // MARK: - Event Handling

        /// Handles question submission
        private func handleSubmit(question: String) {
            onSubmit?(question, currentContentResult)
            hide()
        }

        /// Handles opening the main window with the question
        private func handleOpenMainWindow(question: String) {
            onOpenMainWindow?(question, currentContentResult)
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
            // Optionally hide when losing focus
            // hide()
        }

        func windowWillClose(_: Notification) {
            isVisible = false
            currentContentResult = nil
        }
    }
#endif

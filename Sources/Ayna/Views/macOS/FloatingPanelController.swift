// swiftformat:options --ifdef no-indent
#if os(macOS)

#if os(macOS)
import AppKit
import SwiftUI

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

@MainActor
final class FloatingPanelController: NSObject, ObservableObject {
    static let shared = FloatingPanelController()

    private var panel: KeyablePanel?

    private var hostingView: NSHostingView<AnyView>?

    @Published private(set) var isVisible: Bool = false

    var onSubmit: ((String, AppContentResult?) -> Void)?

    override private init() {
        super.init()
    }

    func show(conversationManager: ConversationManager) {
        if panel == nil {
            createPanel()
        }

        updateContentView(conversationManager: conversationManager)

        positionPanelCentered()

        panel?.alphaValue = 0
        panel?.setFrame(
            NSRect(
                x: panel?.frame.origin.x ?? 0,
                y: panel?.frame.origin.y ?? 0,
                width: 600,
                height: 88
            ),
            display: true
        )

        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        panel?.makeFirstResponder(panel?.contentView)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel?.animator().alphaValue = 1
        }

        isVisible = true

        DiagnosticsLogger.log(
            .attachFromApp,
            level: .info,
            message: "Spotlight panel shown"
        )
    }

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
            .attachFromApp,
            level: .info,
            message: "Spotlight panel hidden"
        )
    }

    func toggle(conversationManager: ConversationManager) {
        if isVisible {
            hide()
        } else {
            show(conversationManager: conversationManager)
        }
    }

    private func createPanel() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 88),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false

        panel.becomesKeyOnlyIfNeeded = false

        panel.delegate = self

        self.panel = panel

        DiagnosticsLogger.log(
            .attachFromApp,
            level: .info,
            message: "Spotlight panel created"
        )
    }

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

    private func positionPanelCentered() {
        guard let panel, let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let panelWidth: CGFloat = 600

        let posX = screenFrame.midX - panelWidth / 2

        let posY = screenFrame.minY + screenFrame.height * 0.7

        panel.setFrameOrigin(NSPoint(x: posX, y: posY))
    }

    private func handleSubmit(question: String, contentResult: AppContentResult?) {
        onSubmit?(question, contentResult)
        hide()
    }
}

extension FloatingPanelController: NSWindowDelegate {
    func windowDidResignKey(_: Notification) {
        hide()
    }

    func windowWillClose(_: Notification) {
        isVisible = false
    }
}
#endif
#endif

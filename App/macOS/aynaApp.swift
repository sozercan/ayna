//
//  aynaApp.swift
//  ayna
//
//  Created on 11/2/25.
//

import AppKit
import OSLog
import SwiftUI

/// Activity type for Handoff from Apple Watch
private let handoffActivityType = "com.sertacozercan.ayna.conversation"

@MainActor
private var uiTestWindowObserver: NSObjectProtocol?

@MainActor
private var uiTestFallbackWindow: NSWindow?

@main
struct aynaApp: App {
    @NSApplicationDelegateAdaptor(AynaAppDelegate.self) private var appDelegate
    @StateObject private var conversationManager: ConversationManager
    @StateObject private var floatingPanelController = FloatingPanelController.shared

    init() {
        AppPreferences.registerDefaults()
        UITestEnvironment.configureIfNeeded()

        // Configure attachment loader
        Message.attachmentLoader = { path in
            AttachmentStorage.shared.load(path: path)
        }

        let manager: ConversationManager = if UITestEnvironment.isEnabled {
            UITestEnvironment.makeConversationManager()
        } else {
            ConversationManager()
        }
        _conversationManager = StateObject(wrappedValue: manager)

        if UITestEnvironment.isEnabled {
            Task { await prepareWindowsForUITests(using: manager) }
        }

        guard !UITestEnvironment.shouldSkipMCPInitialization else { return }

        // Initialize MCP servers on app launch and log availability
        Task {
            await MCPServerManager.shared.connectToAllEnabledServers()
            DiagnosticsLogger.log(
                .app,
                level: .info,
                message: "✅ MCP initialization complete. Available tools: \(MCPServerManager.shared.availableTools.count)",
                metadata: ["toolCount": "\(MCPServerManager.shared.availableTools.count)"]
            )
        }

        // Initialize "Work with Apps" if enabled
        Task { @MainActor in
            setupWorkWithApps(conversationManager: manager)
        }
    }

    var body: some Scene {
        WindowGroup {
            MacContentView()
                .environmentObject(conversationManager)
                .onAppear {
                    // If running UI tests, ensure window is ready
                    if UITestEnvironment.isEnabled {
                        Task { @MainActor in
                            if let window = NSApplication.shared.windows.first {
                                window.makeKeyAndOrderFront(nil)
                            }
                        }
                    }
                }
                .onContinueUserActivity(handoffActivityType) { activity in
                    handleHandoff(activity)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") {
                    NotificationCenter.default.post(
                        name: .newConversationRequested,
                        object: nil
                    )
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        Settings {
            MacSettingsView()
                .environmentObject(conversationManager)
                .onOpenURL { url in
                    Task {
                        await GitHubOAuthService.shared.handleCallbackURL(url)
                    }
                }
        }
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") {
                    NotificationCenter.default.post(
                        name: .newConversationRequested,
                        object: nil
                    )
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    @MainActor
    private func handleHandoff(_ activity: NSUserActivity) {
        guard let userInfo = activity.userInfo,
              let conversationIdString = userInfo["conversationId"] as? String,
              let conversationId = UUID(uuidString: conversationIdString)
        else {
            DiagnosticsLogger.log(
                .app,
                level: .error,
                message: "❌ Failed to parse Handoff activity"
            )
            return
        }

        // Check if the conversation exists
        if conversationManager.conversations.contains(where: { $0.id == conversationId }) {
            conversationManager.selectedConversationId = conversationId
            DiagnosticsLogger.log(
                .app,
                level: .info,
                message: "✅ Handoff: Opened conversation from Watch",
                metadata: ["conversationId": conversationIdString]
            )
        } else {
            DiagnosticsLogger.log(
                .app,
                level: .default,
                message: "⚠️ Handoff: Conversation not found",
                metadata: ["conversationId": conversationIdString]
            )
        }
    }
}

@MainActor
final class AynaAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_: Notification) {
        DiagnosticsLogger.log(
            .app,
            level: .info,
            message: "🛑 Application terminating; disconnecting MCP servers"
        )
        MCPServerManager.shared.disconnectAllServers()

        // Clean up Work with Apps
        GlobalHotkeyService.shared.unregister()
        AccessibilityService.shared.stopMonitoring()
    }
}

// MARK: - Work with Apps Setup

@MainActor
private func setupWorkWithApps(conversationManager: ConversationManager) {
    guard AppPreferences.workWithAppsEnabled else {
        DiagnosticsLogger.log(
            .workWithApps,
            level: .info,
            message: "Work with Apps is disabled"
        )
        return
    }

    // Register the global hotkey
    do {
        try GlobalHotkeyService.shared.registerDefault()
    } catch {
        DiagnosticsLogger.log(
            .workWithApps,
            level: .error,
            message: "Failed to register global hotkey",
            metadata: ["error": error.localizedDescription]
        )
        return
    }

    // Start accessibility permission monitoring
    AccessibilityService.shared.startMonitoring()

    // Set up hotkey handler
    GlobalHotkeyService.shared.onHotkeyPressed = { capturedApp in
        Task { @MainActor in
            await handleWorkWithAppsHotkey(capturedApp: capturedApp, conversationManager: conversationManager)
        }
    }

    // Set up floating panel handlers
    FloatingPanelController.shared.onSubmit = { question, contentResult in
        handleWorkWithAppsSubmit(
            question: question,
            contentResult: contentResult,
            conversationManager: conversationManager,
            openMainWindow: false
        )
    }

    FloatingPanelController.shared.onOpenMainWindow = { question, contentResult in
        handleWorkWithAppsSubmit(
            question: question,
            contentResult: contentResult,
            conversationManager: conversationManager,
            openMainWindow: true
        )
    }

    DiagnosticsLogger.log(
        .workWithApps,
        level: .info,
        message: "✅ Work with Apps initialized"
    )
}

@MainActor
private func handleWorkWithAppsHotkey(capturedApp: NSRunningApplication?, conversationManager: ConversationManager) async {
    DiagnosticsLogger.log(
        .workWithApps,
        level: .info,
        message: "Hotkey handler called",
        metadata: [
            "capturedApp": capturedApp?.localizedName ?? "nil",
            "bundleId": capturedApp?.bundleIdentifier ?? "nil"
        ]
    )

    let contentResult: AppContentResult = if let app = capturedApp {
        // Extract content from the captured app
        await AppContentService.shared.extractContent(from: app)
    } else {
        .noFocusedApp
    }

    DiagnosticsLogger.log(
        .workWithApps,
        level: .info,
        message: "Content extraction complete",
        metadata: [
            "result": String(describing: contentResult),
            "hasContent": "\(contentResult.content != nil)"
        ]
    )

    // Show the floating panel
    FloatingPanelController.shared.show(with: contentResult, conversationManager: conversationManager)
}

@MainActor
private func handleWorkWithAppsSubmit(
    question: String,
    contentResult: AppContentResult?,
    conversationManager: ConversationManager,
    openMainWindow: Bool
) {
    if let contentResult, case let .success(content) = contentResult {
        // Create conversation with context
        // Note: Smart truncation already applied by extractors, just redact secrets
        let conversation = conversationManager.createConversationWithContext(
            appName: content.appName,
            windowTitle: content.windowTitle,
            contentType: content.contentType.displayName,
            content: content.redacted.content,
            userMessage: question
        )

        DiagnosticsLogger.log(
            .workWithApps,
            level: .info,
            message: "Created conversation with app context",
            metadata: [
                "conversationId": conversation.id.uuidString,
                "appName": content.appName
            ]
        )
    } else {
        // Create regular conversation without context
        conversationManager.createNewConversation(title: "New Conversation")

        if let id = conversationManager.conversations.first?.id {
            let message = Message(role: .user, content: question)
            if let conv = conversationManager.conversation(byId: id) {
                conversationManager.addMessage(to: conv, message: message)
            }
        }

        DiagnosticsLogger.log(
            .workWithApps,
            level: .info,
            message: "Created conversation without context"
        )
    }

    // Open main window if requested
    if openMainWindow {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
private func prepareWindowsForUITests(using manager: ConversationManager) async {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)

    @MainActor
    func ensureFallbackWindowIfNeeded() {
        guard uiTestFallbackWindow == nil else { return }
        let fallbackWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        fallbackWindow.contentView = NSHostingView(
            rootView: MacContentView()
                .environmentObject(manager)
                .frame(minWidth: 900, minHeight: 600)
        )
        fallbackWindow.center()
        configureWindowAppearance(fallbackWindow)
        uiTestFallbackWindow = fallbackWindow
        DiagnosticsLogger.log(
            .app,
            level: .info,
            message: "🪟 Created fallback UI test window"
        )
    }

    var attempts = 0
    while NSApplication.shared.windows.isEmpty, attempts < 50 {
        attempts += 1
        try? await Task.sleep(for: .milliseconds(100))
    }
    DiagnosticsLogger.log(
        .app,
        level: .info,
        message: "🪟 Windows visible after wait: \(NSApplication.shared.windows.count)",
        metadata: ["attempts": "\(attempts)"]
    )
    if NSApplication.shared.windows.isEmpty {
        DiagnosticsLogger.log(
            .app,
            level: .error,
            message: "⚠️ No windows available; creating fallback window for UI tests"
        )
        ensureFallbackWindowIfNeeded()
    }
    for window in NSApplication.shared.windows {
        configureWindowAppearance(window)
    }

    uiTestWindowObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification,
        object: nil,
        queue: nil
    ) { notification in
        guard let window = notification.object as? NSWindow else { return }
        Task { @MainActor in
            configureWindowAppearance(window)
        }
    }
}

@MainActor
private func configureWindowAppearance(_ window: NSWindow) {
    window.styleMask.insert([.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView])
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isOpaque = true
    window.backgroundColor = NSColor.windowBackgroundColor
    window.title = ""
    window.makeKeyAndOrderFront(nil)
}

private struct WindowAppearanceConfigurator: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        let view = WindowObservingView()
        view.onWindowChange = { window in
            guard let window else { return }
            Task { @MainActor in
                configureWindowAppearance(window)
            }
        }
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}

private final class WindowObservingView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

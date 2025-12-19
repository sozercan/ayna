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

        // Initialize WindowGlassManager early so it can observe preference changes
        _ = WindowGlassManager.shared

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
            // Store reference to conversation manager for window creation
            AynaAppDelegate.conversationManager = manager
            setupWorkWithApps(conversationManager: manager)
        }
    }

    var body: some Scene {
        WindowGroup {
            MacContentView()
                .environmentObject(conversationManager)
                .onAppear {
                    // Pass conversation manager to app delegate for deep link handling
                    AynaAppDelegate.conversationManager = conversationManager

                    // If running UI tests, ensure window is ready
                    if UITestEnvironment.isEnabled {
                        Task { @MainActor in
                            if let window = NSApplication.shared.windows.first {
                                window.makeKeyAndOrderFront(nil)
                            }
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .deepLinkNeedsWindow)) { _ in
                    // Window was created by WindowGroup, bring to front
                    Task { @MainActor in
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
                            window.makeKeyAndOrderFront(nil)
                        }
                    }
                }
                .onContinueUserActivity(handoffActivityType) { activity in
                    handleHandoff(activity)
                }
        }
        .handlesExternalEvents(matching: ["main"])
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
final class AynaAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// Reference to manually created window (if any)
    static var manualWindow: NSWindow?

    /// Reference to the hosting controller to prevent deallocation
    static var manualHostingController: NSHostingController<AnyView>?

    /// Reference to the conversation manager for window creation
    weak static var conversationManager: ConversationManager?

    /// Shared instance for window delegate
    static let shared = AynaAppDelegate()

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

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DiagnosticsLogger.log(
            .app,
            level: .info,
            message: "applicationShouldHandleReopen called",
            metadata: ["hasVisibleWindows": "\(flag)"]
        )
        // Return true to let SwiftUI handle window creation
        return true
    }

    /// Opens the main window, creating one if necessary
    @MainActor
    static func openMainWindow() async {
        NSApp.activate(ignoringOtherApps: true)

        // Check if we have a main window (not panel, not settings window)
        let existingWindow = NSApp.windows.first(where: { window in
            !window.isKind(of: NSPanel.self) &&
                window.contentViewController != nil &&
                // Exclude settings window (has "Settings" or "Preferences" in identifier/title)
                !(window.identifier?.rawValue.contains("settings") ?? false) &&
                !(window.identifier?.rawValue.contains("Settings") ?? false) &&
                !(window.title.contains("Settings")) &&
                !(window.title.contains("Preferences")) &&
                // Also check it's not a toolbar-only window
                window.contentView != nil
        })

        if let window = existingWindow {
            window.makeKeyAndOrderFront(nil)
            DiagnosticsLogger.log(
                .app,
                level: .info,
                message: "Opened existing main window"
            )
            return
        }

        // Check if our manual window exists and can be shown
        if let window = manualWindow {
            window.makeKeyAndOrderFront(nil)
            DiagnosticsLogger.log(
                .app,
                level: .info,
                message: "Opened existing manual window"
            )
            return
        }

        // No window exists - create one manually
        DiagnosticsLogger.log(
            .app,
            level: .info,
            message: "No main window found, creating manually"
        )

        guard let manager = conversationManager else {
            DiagnosticsLogger.log(
                .app,
                level: .error,
                message: "Cannot create window - no conversation manager"
            )
            return
        }

        // Create window with SwiftUI content - wrap in AnyView
        let contentView = AnyView(
            MacContentView()
                .environmentObject(manager)
        )

        let hostingController = NSHostingController(rootView: contentView)
        manualHostingController = hostingController // Retain it!

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = hostingController
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false // Keep window alive when closed
        window.center()
        window.setFrameAutosaveName("MainWindow")

        // Apply Liquid Glass effect if enabled
        if AppPreferences.liquidGlassEnabled {
            WindowGlassManager.shared.applyGlassIfEnabled(to: window)
        } else {
            window.isOpaque = true
            window.backgroundColor = NSColor.windowBackgroundColor
        }

        window.makeKeyAndOrderFront(nil)

        manualWindow = window

        DiagnosticsLogger.log(
            .app,
            level: .info,
            message: "Created manual main window"
        )
    }

    /// Handle deep link URLs at the app delegate level to prevent new window creation
    func application(_ app: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }

        // First, ensure we have a window by activating the app
        app.activate(ignoringOtherApps: true)

        // Check if we need to create a window first (app is running but all windows closed)
        let hasVisibleWindow = app.windows.contains { $0.canBecomeMain && !$0.isMiniaturized }

        if !hasVisibleWindow {
            // Open a window by triggering the WindowGroup
            // Use NSWorkspace to open a neutral URL that matches handlesExternalEvents
            if let mainURL = URL(string: "ayna://main") {
                NSWorkspace.shared.open(mainURL)
            }
            // Small delay to let the window appear before handling the actual deep link
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                await self.handleDeepLinkURL(url, app: app)
            }
        } else {
            // Window exists, handle immediately
            Task { @MainActor in
                await self.handleDeepLinkURL(url, app: app)
            }
        }
    }

    @MainActor
    private func handleDeepLinkURL(_ url: URL, app: NSApplication) async {
        await DeepLinkManager.shared.handle(url: url)

        DiagnosticsLogger.log(
            .app,
            level: .fault,
            message: "🔗 DEBUG AppDelegate: after handle - pendingAddModel=\(String(describing: DeepLinkManager.shared.pendingAddModel)), pendingChat=\(String(describing: DeepLinkManager.shared.pendingChat))"
        )

        // Handle chat deep links by starting a conversation
        // BUT only if there's no pending add-model confirmation (unified flow)
        if DeepLinkManager.shared.pendingAddModel == nil,
           let chatRequest = DeepLinkManager.shared.pendingChat,
           let manager = Self.conversationManager
        {
            DiagnosticsLogger.log(
                .app,
                level: .fault,
                message: "🔗 DEBUG AppDelegate: Starting conversation (no pending add model)"
            )
            _ = manager.startConversation(
                model: chatRequest.model,
                prompt: chatRequest.prompt,
                systemPrompt: chatRequest.systemPrompt
            )
            DeepLinkManager.shared.clearPendingChat()
        } else if DeepLinkManager.shared.pendingAddModel != nil {
            DiagnosticsLogger.log(
                .app,
                level: .fault,
                message: "🔗 DEBUG AppDelegate: NOT starting conversation - waiting for add model confirmation"
            )
        }

        // Bring window to front
        if let window = app.windows.first(where: { $0.canBecomeMain }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Work with Apps Setup

@MainActor
private func setupWorkWithApps(conversationManager: ConversationManager) {
    guard AppPreferences.attachFromAppEnabled else {
        DiagnosticsLogger.log(
            .attachFromApp,
            level: .info,
            message: "Attach from App is disabled"
        )
        return
    }

    // Register the global hotkey
    do {
        try GlobalHotkeyService.shared.registerDefault()
    } catch {
        DiagnosticsLogger.log(
            .attachFromApp,
            level: .error,
            message: "Failed to register global hotkey",
            metadata: ["error": error.localizedDescription]
        )
        return
    }

    // Start accessibility permission monitoring
    AccessibilityService.shared.startMonitoring()

    // Set up hotkey handler - opens Spotlight-style panel (no auto-capture)
    GlobalHotkeyService.shared.onHotkeyPressed = { _ in
        Task { @MainActor in
            // Simply show the Spotlight panel - user will manually attach context if needed
            FloatingPanelController.shared.show(conversationManager: conversationManager)
        }
    }

    // Set up floating panel submit handler
    FloatingPanelController.shared.onSubmit = { question, contentResult in
        handleWorkWithAppsSubmit(
            question: question,
            contentResult: contentResult,
            conversationManager: conversationManager,
            openMainWindow: true // Always open main window
        )
    }

    DiagnosticsLogger.log(
        .attachFromApp,
        level: .info,
        message: "✅ Attach from App initialized (Spotlight mode)"
    )
}

@MainActor
private func handleWorkWithAppsSubmit(
    question: String,
    contentResult: AppContentResult?,
    conversationManager: ConversationManager,
    openMainWindow: Bool
) {
    DiagnosticsLogger.log(
        .attachFromApp,
        level: .info,
        message: "handleWorkWithAppsSubmit called",
        metadata: [
            "question": question,
            "hasContent": "\(contentResult != nil)"
        ]
    )

    var conversationId: UUID?

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
        conversationId = conversation.id

        DiagnosticsLogger.log(
            .attachFromApp,
            level: .info,
            message: "Created conversation with app context",
            metadata: [
                "conversationId": conversation.id.uuidString,
                "appName": content.appName
            ]
        )
    } else {
        // Create regular conversation without context
        conversationManager.createNewConversation(title: "Quick Chat")

        if let conv = conversationManager.conversations.first {
            let message = Message(role: .user, content: question)
            conversationManager.addMessage(to: conv, message: message)
            conversationId = conv.id

            // Select this conversation
            conversationManager.selectedConversationId = conv.id
        }

        DiagnosticsLogger.log(
            .attachFromApp,
            level: .info,
            message: "Created conversation without context",
            metadata: ["conversationId": conversationId?.uuidString ?? "nil"]
        )
    }

    // Open main window if requested
    if openMainWindow {
        Task {
            // Use the AppDelegate helper to open/create window
            await AynaAppDelegate.openMainWindow()

            // Wait for window to be ready
            try? await Task.sleep(for: .milliseconds(500))

            // Ensure main window (not settings) is visible and focused
            if let window = NSApp.windows.first(where: {
                !$0.isKind(of: NSPanel.self) &&
                    !($0.title.contains("Settings") || $0.title.contains("Preferences"))
            }) {
                window.makeKeyAndOrderFront(nil)
            }

            // Trigger AI response
            if let convId = conversationId {
                try? await Task.sleep(for: .milliseconds(200))
                NotificationCenter.default.post(
                    name: .sendPendingMessage,
                    object: nil,
                    userInfo: ["conversationId": convId]
                )
                DiagnosticsLogger.log(
                    .attachFromApp,
                    level: .info,
                    message: "Posted sendPendingMessage notification",
                    metadata: ["conversationId": convId.uuidString]
                )
            }
        }
    }
}

extension Notification.Name {
    static let deepLinkNeedsWindow = Notification.Name("deepLinkNeedsWindow")
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
    window.title = ""

    // Apply Liquid Glass effect if enabled (handles isOpaque and backgroundColor)
    // Otherwise, set standard opaque appearance
    if AppPreferences.liquidGlassEnabled {
        WindowGlassManager.shared.applyGlassIfEnabled(to: window)
    } else {
        window.isOpaque = true
        window.backgroundColor = NSColor.windowBackgroundColor
    }

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

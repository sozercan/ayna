// swiftformat:options --ifdef no-indent
#if os(macOS)

import AppKit
import OSLog
import SwiftUI

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
    @State private var updaterService = UpdaterService()

    init() {
        AppPreferences.registerDefaults()
        UITestEnvironment.configureIfNeeded()

        Message.attachmentLoader = { path in
            AttachmentStorage.shared.load(path: path)
        }
        Message.attachmentAsyncLoader = { path in
            await AttachmentStorage.shared.loadData(path: path)
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

        Task {
            await MCPServerManager.shared.connectToAllEnabledServers()
            DiagnosticsLogger.log(
                .app,
                level: .info,
                message: "✅ MCP initialization complete. Available tools: \(MCPServerManager.shared.availableTools.count)",
                metadata: ["toolCount": "\(MCPServerManager.shared.availableTools.count)"]
            )
        }

        Task { @MainActor in
            AynaAppDelegate.attachConversationManager(manager)
            MemoryContextProvider.shared.attachConversationSource(manager)
            setupWorkWithApps(conversationManager: manager)
        }
    }

    var body: some Scene {
        WindowGroup {
            MacContentView()
                .environmentObject(conversationManager)
                .onAppear {
                    AynaAppDelegate.attachConversationManager(conversationManager)

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
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updaterService.checkForUpdates()
                }
                .disabled(!updaterService.canCheckForUpdates)
            }
        }

        Settings {
            MacSettingsView()
                .environmentObject(conversationManager)
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
    static var manualWindow: NSWindow?

    static var manualHostingController: NSHostingController<AnyView>?

    weak static var conversationManager: ConversationManager?

    private var deepLinkHandlingTask: Task<Void, Never>?

    static func attachConversationManager(_ manager: ConversationManager) {
        conversationManager = manager
    }

    static let shared = AynaAppDelegate()

    func applicationWillTerminate(_: Notification) {
        DiagnosticsLogger.log(
            .app,
            level: .info,
            message: "🛑 Application terminating; disconnecting MCP servers"
        )
        MCPServerManager.shared.disconnectAllServers()

        GlobalHotkeyService.shared.unregister()
        AccessibilityService.shared.stopMonitoring()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await Self.conversationManager?.flushPendingSaves()
                    await MemoryContextProvider.shared.saveAll()
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(5))
                }
                await group.next()
                group.cancelAll()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DiagnosticsLogger.log(
            .app,
            level: .info,
            message: "applicationShouldHandleReopen called",
            metadata: ["hasVisibleWindows": "\(flag)"]
        )
        return true
    }

    @MainActor
    static func openMainWindow() async {
        NSApp.activate(ignoringOtherApps: true)

        let existingWindow = NSApp.windows.first(where: { window in
            !window.isKind(of: NSPanel.self) &&
                window.contentViewController != nil &&
                !(window.identifier?.rawValue.contains("settings") ?? false) &&
                !(window.identifier?.rawValue.contains("Settings") ?? false) &&
                !(window.title.contains("Settings")) &&
                !(window.title.contains("Preferences")) &&
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

        if let window = manualWindow {
            window.makeKeyAndOrderFront(nil)
            DiagnosticsLogger.log(
                .app,
                level: .info,
                message: "Opened existing manual window"
            )
            return
        }

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

        let contentView = AnyView(
            MacContentView()
                .environmentObject(manager)
        )

        let hostingController = NSHostingController(rootView: contentView)
        manualHostingController = hostingController

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = hostingController
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.makeKeyAndOrderFront(nil)

        manualWindow = window

        DiagnosticsLogger.log(
            .app,
            level: .info,
            message: "Created manual main window"
        )
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        for url in urls {
            enqueueDeepLinkURL(url, app: app)
        }
    }

    private func enqueueDeepLinkURL(_ url: URL, app: NSApplication) {
        let precedingTask = deepLinkHandlingTask
        deepLinkHandlingTask = Task { @MainActor [weak self] in
            await precedingTask?.value
            guard let self else { return }
            await self.processDeepLinkURL(url, app: app)
        }
    }

    private func processDeepLinkURL(_ url: URL, app: NSApplication) async {
        app.activate(ignoringOtherApps: true)

        let hasVisibleWindow = app.windows.contains { $0.canBecomeMain && !$0.isMiniaturized }

        if !hasVisibleWindow {
            if let mainURL = URL(string: "ayna://main") {
                NSWorkspace.shared.open(mainURL)
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        await handleDeepLinkURL(url, app: app)
    }

    @MainActor
    private func handleDeepLinkURL(_ url: URL, app: NSApplication) async {
        if let manager = await waitForReadyConversationManager() {
            await DeepLinkManager.shared.handle(url: url)

            DiagnosticsLogger.log(
                .app,
                level: .fault,
                message: "🔗 DEBUG AppDelegate: after handle - pendingAddModel=\(String(describing: DeepLinkManager.shared.pendingAddModel)), pendingChat=\(String(describing: DeepLinkManager.shared.pendingChat))"
            )

            if let chatRequest = DeepLinkManager.shared.consumeNextReadyChat() {
                Self.startDeepLinkConversation(chatRequest, using: manager)
            }

            if DeepLinkManager.shared.pendingAddModel != nil {
                DiagnosticsLogger.log(
                    .app,
                    level: .fault,
                    message: "🔗 DEBUG AppDelegate: NOT starting conversation - waiting for add model confirmation"
                )
            }
        } else {
            DiagnosticsLogger.log(
                .app,
                level: .error,
                message: "Unable to handle deep link before conversation storage became ready"
            )
        }

        if let window = app.windows.first(where: { $0.canBecomeMain }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func waitForReadyConversationManager() async -> ConversationManager? {
        for _ in 0 ..< 100 {
            if let manager = Self.conversationManager {
                await manager.loadingTask?.value
                return manager
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private static func startDeepLinkConversation(
        _ chatRequest: ChatRequest,
        using manager: ConversationManager
    ) {
        DiagnosticsLogger.log(
            .app,
            level: .fault,
            message: "🔗 DEBUG AppDelegate: Starting ready deep-link conversation"
        )
        _ = manager.startConversation(
            model: chatRequest.model,
            prompt: chatRequest.prompt,
            systemPrompt: chatRequest.systemPrompt
        )
    }
}

@MainActor
private func setupWorkWithApps(conversationManager: ConversationManager) {
    defer {
        if AppPreferences.attachFromAppEnabled {
            AccessibilityService.shared.startMonitoring()
            do {
                try GlobalHotkeyService.shared.registerSaved()
            } catch {
                DiagnosticsLogger.log(
                    .attachFromApp,
                    level: .error,
                    message: "Failed to register global hotkey",
                    metadata: ["error": error.localizedDescription]
                )
            }
        } else {
            DiagnosticsLogger.log(
                .attachFromApp,
                level: .info,
                message: "Attach from App is disabled"
            )
        }
    }

    GlobalHotkeyService.shared.onHotkeyPressed = { _ in
        Task { @MainActor in
            FloatingPanelController.shared.show(conversationManager: conversationManager)
        }
    }

    FloatingPanelController.shared.onSubmit = { question, contentResult in
        handleWorkWithAppsSubmit(
            question: question,
            contentResult: contentResult,
            conversationManager: conversationManager,
            openMainWindow: true
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
        conversationManager.createNewConversation(title: "Quick Chat")

        if let conv = conversationManager.conversations.first {
            let message = Message(role: .user, content: question)
            conversationManager.addMessage(to: conv, message: message)
            conversationId = conv.id

            conversationManager.selectedConversationId = conv.id
        }

        DiagnosticsLogger.log(
            .attachFromApp,
            level: .info,
            message: "Created conversation without context",
            metadata: ["conversationId": conversationId?.uuidString ?? "nil"]
        )
    }

    if openMainWindow {
        Task {
            await AynaAppDelegate.openMainWindow()

            try? await Task.sleep(for: .milliseconds(500))

            if let window = NSApp.windows.first(where: {
                !$0.isKind(of: NSPanel.self) &&
                    !($0.title.contains("Settings") || $0.title.contains("Preferences"))
            }) {
                window.makeKeyAndOrderFront(nil)
            }

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
#endif

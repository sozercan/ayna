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

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: MainWindowCoordinator.windowID) {
            MacContentView()
                .environmentObject(conversationManager)
                .onAppear {
                    AynaAppDelegate.attachConversationManager(conversationManager)
                    MainWindowCoordinator.shared.register(openWindow: {
                        openWindow(id: MainWindowCoordinator.windowID)
                    })
                    MainWindowCoordinator.shared.markMainWindowReady()

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
final class MainWindowCoordinator {
    static let windowID = "main"
    static let shared = MainWindowCoordinator()

    private var openWindowAction: (@MainActor () -> Void)?
    private var readinessContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var isMainWindowReady = false
    private(set) var isOpenRequestInFlight = false

    init() {}

    func register(openWindow: @escaping @MainActor () -> Void) {
        openWindowAction = openWindow
    }

    func markMainWindowReady() {
        isMainWindowReady = true
        isOpenRequestInFlight = false
        let continuations = readinessContinuations
        readinessContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func markMainWindowClosed() {
        isMainWindowReady = false
        isOpenRequestInFlight = false
    }

    func existingMainWindow(in windows: [NSWindow]) -> NSWindow? {
        windows.first { window in
            !window.isKind(of: NSPanel.self) &&
                window.canBecomeMain &&
                window.contentViewController != nil &&
                !(window.identifier?.rawValue.contains("settings") ?? false) &&
                !(window.identifier?.rawValue.contains("Settings") ?? false) &&
                !window.title.contains("Settings") &&
                !window.title.contains("Preferences") &&
                window.contentView != nil
        }
    }

    @discardableResult
    func openOrFocusMainWindow(
        windows: @MainActor () -> [NSWindow] = { NSApp.windows },
        activateApp: @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    ) -> Bool {
        activateApp()

        if let window = existingMainWindow(in: windows()) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            markMainWindowReady()
            DiagnosticsLogger.log(
                .app,
                level: .info,
                message: "Opened existing main window"
            )
            return true
        }

        isMainWindowReady = false
        if isOpenRequestInFlight {
            DiagnosticsLogger.log(
                .app,
                level: .info,
                message: "SwiftUI main WindowGroup open request already in flight"
            )
            return true
        }

        if let openWindowAction {
            isOpenRequestInFlight = true
            openWindowAction()
            DiagnosticsLogger.log(
                .app,
                level: .info,
                message: "Requested SwiftUI main WindowGroup"
            )
            return true
        }

        isOpenRequestInFlight = false
        DiagnosticsLogger.log(
            .app,
            level: .default,
            message: "SwiftUI main WindowGroup open action not yet registered"
        )
        return false
    }

    func waitUntilMainWindowReady() async {
        if isMainWindowReady {
            return
        }
        await withCheckedContinuation { continuation in
            readinessContinuations.append(continuation)
        }
    }

    func resetForTesting() {
        openWindowAction = nil
        isMainWindowReady = false
        isOpenRequestInFlight = false
        let continuations = readinessContinuations
        readinessContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

@MainActor
final class AynaAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak static var conversationManager: ConversationManager?
    private static var managerContinuations: [CheckedContinuation<ConversationManager, Never>] = []

    private var deepLinkHandlingTask: Task<Void, Never>?

    static func attachConversationManager(_ manager: ConversationManager) {
        conversationManager = manager
        let continuations = managerContinuations
        managerContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: manager)
        }
    }

    static func resetForTesting() {
        conversationManager = nil
        managerContinuations.removeAll()
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
        if !flag {
            MainWindowCoordinator.shared.openOrFocusMainWindow()
        }
        return true
    }

    @MainActor
    static func openMainWindow() async {
        _ = MainWindowCoordinator.shared.openOrFocusMainWindow()
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
        MainWindowCoordinator.shared.openOrFocusMainWindow(
            windows: { app.windows },
            activateApp: { app.activate(ignoringOtherApps: true) }
        )
        await handleDeepLinkURL(url, app: app)
    }

    @MainActor
    private func handleDeepLinkURL(_ url: URL, app: NSApplication) async {
        let manager = await waitForReadyConversationManager()
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

        MainWindowCoordinator.shared.openOrFocusMainWindow(
            windows: { app.windows },
            activateApp: { app.activate(ignoringOtherApps: true) }
        )
    }

    static func waitForAttachedConversationManager() async -> ConversationManager {
        if let manager = conversationManager {
            return manager
        }
        return await withCheckedContinuation { continuation in
            managerContinuations.append(continuation)
        }
    }

    private func waitForReadyConversationManager() async -> ConversationManager {
        let manager = await Self.waitForAttachedConversationManager()
        await manager.loadingTask?.value
        return manager
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
            conversationManager.queuePendingSend(for: conv.id)
        }

        DiagnosticsLogger.log(
            .attachFromApp,
            level: .info,
            message: "Created conversation without context",
            metadata: ["conversationId": conversationId?.uuidString ?? "nil"]
        )
    }

    if openMainWindow {
        MainWindowCoordinator.shared.openOrFocusMainWindow()
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

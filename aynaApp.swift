//
//  aynaApp.swift
//  ayna
//
//  Created on 11/2/25.
//

import AppKit
import OSLog
import SwiftUI

@MainActor
private var uiTestWindowObserver: NSObjectProtocol?

@MainActor
private var uiTestFallbackWindow: NSWindow?

@main
struct aynaApp: App {
    @StateObject private var conversationManager: ConversationManager

    init() {
        AppPreferences.registerDefaults()
        UITestEnvironment.configureIfNeeded()

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

        // Initialize MCP servers on app launch with error handling
        Task {
            do {
                await MCPServerManager.shared.connectToAllEnabledServers()
                DiagnosticsLogger.log(
                    .app,
                    level: .info,
                    message: "✅ MCP initialization complete. Available tools: \(MCPServerManager.shared.availableTools.count)",
                    metadata: ["toolCount": "\(MCPServerManager.shared.availableTools.count)"],
                )
            } catch {
                DiagnosticsLogger.log(
                    .app,
                    level: .error,
                    message: "⚠️ MCP initialization encountered errors",
                    metadata: ["error": error.localizedDescription],
                )
                DiagnosticsLogger.log(
                    .app,
                    level: .info,
                    message: "App will continue without MCP servers.",
                )
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(conversationManager)
                .frame(minWidth: 900, minHeight: 600)
                .background(WindowAppearanceConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") {
                    NotificationCenter.default.post(name: .newConversationRequested, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(conversationManager)
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
            defer: false,
        )
        fallbackWindow.contentView = NSHostingView(
            rootView: ContentView()
                .environmentObject(manager)
                .frame(minWidth: 900, minHeight: 600),
        )
        fallbackWindow.center()
        configureWindowAppearance(fallbackWindow)
        uiTestFallbackWindow = fallbackWindow
        DiagnosticsLogger.log(
            .app,
            level: .info,
            message: "🪟 Created fallback UI test window",
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
        metadata: ["attempts": "\(attempts)"],
    )
    if NSApplication.shared.windows.isEmpty {
        DiagnosticsLogger.log(
            .app,
            level: .error,
            message: "⚠️ No windows available; creating fallback window for UI tests",
        )
        ensureFallbackWindowIfNeeded()
    }
    NSApplication.shared.windows.forEach(configureWindowAppearance)

    uiTestWindowObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification,
        object: nil,
        queue: nil,
    ) { notification in
        guard let window = notification.object as? NSWindow else { return }
        Task { await configureWindowAppearance(window) }
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
            Task { await configureWindowAppearance(window) }
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

//
//  aynaApp.swift
//  ayna
//
//  Created on 11/2/25.
//

import SwiftUI

@main
struct aynaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var conversationManager = ConversationManager()

    init() {
        // Initialize MCP servers on app launch with error handling
        Task {
            do {
                await MCPServerManager.shared.connectToAllEnabledServers()
                print("✅ MCP initialization complete. Available tools: \(MCPServerManager.shared.availableTools.count)")
            } catch {
                print("⚠️ MCP initialization encountered errors: \(error.localizedDescription)")
                print("App will continue without MCP servers.")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(conversationManager)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    // Pass conversation manager to app delegate for notch window
                    appDelegate.conversationManager = conversationManager
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") {
                    conversationManager.createNewConversation()
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

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var notchWindow: NotchWindow?
    var mainWindow: NSWindow?
    var conversationManager: ConversationManager?
    private var screenChangeObserver: NSObjectProtocol?
    
    @AppStorage("enableNotchIntegration") private var enableNotchIntegration = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 App finished launching")
        
        // Find and store reference to main window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.mainWindow = NSApp.windows.first(where: { !($0 is NotchWindow) })
            print("👁️ Found main window: \(self?.mainWindow != nil)")
        }
        
        if enableNotchIntegration {
            print("✅ Notch integration enabled, will setup notch window when conversation manager is available")
            
            // Set activation policy to accessory (no dock icon when notch is enabled)
            NSApp.setActivationPolicy(.accessory)
            
            // Listen for screen changes
            screenChangeObserver = NotchPositioningService.shared.observeScreenChanges { [weak self] in
                self?.repositionNotchWindow()
            }
            
            // Setup notch window after a brief delay to ensure conversation manager is set
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.setupNotchWindowIfNeeded()
            }
        } else {
            print("ℹ️ Notch integration disabled")
        }
    }
    
    private func setupNotchWindowIfNeeded() {
        guard conversationManager != nil else {
            print("⚠️ Conversation manager not yet available, will retry")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.setupNotchWindowIfNeeded()
            }
            return
        }
        setupNotchWindow()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func setupNotchWindow() {
        let positioningService = NotchPositioningService.shared
        let screen = positioningService.getNotchScreen()
        let size = positioningService.getCollapsedNotchSize(screen: screen)
        let position = positioningService.getNotchWindowPosition(screen: screen, windowSize: size)
        
        let contentRect = NSRect(origin: position, size: size)
        
        notchWindow = NotchWindow(contentRect: contentRect)
        
        guard let notchWindow = notchWindow else { return }
        
        // Create SwiftUI hosting view
        let notchView = NotchChatView()
            .environmentObject(conversationManager ?? ConversationManager())
        
        let hostingView = NSHostingView(rootView: notchView)
        notchWindow.contentView = hostingView
        
        // Show the window
        notchWindow.orderFrontRegardless()
        
        print("✅ Notch window created at position: \(position), size: \(size)")
    }
    
    private func repositionNotchWindow() {
        guard let notchWindow = notchWindow else { return }
        
        let positioningService = NotchPositioningService.shared
        let screen = positioningService.getNotchScreen()
        let size = notchWindow.frame.size
        let position = positioningService.getNotchWindowPosition(screen: screen, windowSize: size)
        
        notchWindow.setFrameOrigin(position)
        
        print("🔄 Notch window repositioned to: \(position)")
    }
    
    func showMainWindow() {
        print("📍 Attempting to show main window...")
        
        // Switch to regular mode
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
        // Try stored reference first
        if let window = mainWindow {
            window.orderFront(nil)
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            print("✅ Main window shown from stored reference")
            return
        }
        
        // Otherwise find it
        if let window = NSApp.windows.first(where: { !($0 is NotchWindow) }) {
            mainWindow = window
            window.orderFront(nil)
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            print("✅ Main window shown from search")
        } else {
            print("⚠️ No main window found")
        }
    }
}

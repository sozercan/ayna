//
//  aynaApp.swift
//  ayna
//
//  Created on 11/2/25.
//

import SwiftUI
import OSLog

@main
struct aynaApp: App {
    @StateObject private var conversationManager: ConversationManager

    init() {
        UITestEnvironment.configureIfNeeded()
        if UITestEnvironment.isEnabled {
            _conversationManager = StateObject(wrappedValue: UITestEnvironment.makeConversationManager())
        } else {
            _conversationManager = StateObject(wrappedValue: ConversationManager())
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
                    metadata: ["toolCount": "\(MCPServerManager.shared.availableTools.count)"]
                )
            } catch {
                DiagnosticsLogger.log(
                    .app,
                    level: .error,
                    message: "⚠️ MCP initialization encountered errors",
                    metadata: ["error": error.localizedDescription]
                )
                DiagnosticsLogger.log(
                    .app,
                    level: .info,
                    message: "App will continue without MCP servers."
                )
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(conversationManager)
                .frame(minWidth: 900, minHeight: 600)
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

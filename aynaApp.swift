//
//  aynaApp.swift
//  ayna
//
//  Created on 11/2/25.
//

import SwiftUI

@main
struct aynaApp: App {
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

//
//  AynaIOSApp.swift
//  ayna
//
//  Created on 11/22/25.
//

import SwiftUI

@main
struct AynaIOSApp: App {
    @StateObject private var conversationManager = ConversationManager()
    @StateObject private var openAIService = OpenAIService.shared

    init() {
        // Configure attachment loader if AttachmentStorage is available
        // Note: Ensure Services/AttachmentStorage.swift is added to the iOS target
        #if canImport(Foundation)
            // Message.attachmentLoader = { path in AttachmentStorage.shared.load(path: path) }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            IOSContentView()
                .environmentObject(conversationManager)
                .environmentObject(openAIService)
                .onOpenURL { url in
                    Task {
                        await GitHubOAuthService.shared.handleCallbackURL(url)
                    }
                }
        }
    }
}

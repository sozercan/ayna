import Foundation
import SwiftUI

@MainActor
@Observable
final class SessionMetadataService {
    static let shared = SessionMetadataService()

    var isEnabled: Bool {
        get { AppPreferences.storage.bool(forKey: "sessionMetadataEnabled") }
        set { AppPreferences.storage.set(newValue, forKey: "sessionMetadataEnabled") }
    }

    private init() {
        AppPreferences.storage.register(defaults: ["sessionMetadataEnabled": true])
    }

    func collectMetadata() -> SessionMetadata {
        SessionMetadata(
            deviceType: currentDeviceType,
            platform: currentPlatform,
            appVersion: currentAppVersion,
            localTime: Date(),
            timezone: .current,
            isDarkMode: isDarkModeEnabled,
            conversationPatterns: nil
        )
    }

    func formattedForContext() -> String? {
        guard isEnabled else { return nil }
        return collectMetadata().formattedForContext()
    }

    private var currentDeviceType: SessionMetadata.DeviceType {
        #if os(macOS)
            .desktop
        #elseif os(iOS)
            if UIDevice.current.userInterfaceIdiom == .pad {
                .tablet
            } else {
                .phone
            }
        #elseif os(watchOS)
            .watch
        #else
            .desktop
        #endif
    }

    private var currentPlatform: SessionMetadata.Platform {
        #if os(macOS)
            .macOS
        #elseif os(iOS)
            .iOS
        #elseif os(watchOS)
            .watchOS
        #else
            .macOS
        #endif
    }

    private var currentAppVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            .flatMap { $0.hasPrefix("$(") ? nil : $0 } ?? "1.0"
    }

    private var isDarkModeEnabled: Bool {
        #if os(macOS)
            NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        #elseif os(iOS)
            UITraitCollection.current.userInterfaceStyle == .dark
        #elseif os(watchOS)
            true
        #else
            false
        #endif
    }

    func computeConversationPatterns(from conversations: [Conversation]) -> SessionMetadata.ConversationPatterns? {
        guard !conversations.isEmpty else { return nil }

        let allUserMessages = conversations.flatMap { $0.messages.filter { $0.role == .user } }
        let averageLength: Int? = if !allUserMessages.isEmpty {
            allUserMessages.map(\.content.count).reduce(0, +) / allUserMessages.count
        } else {
            nil
        }

        let averageDepth: Int? = if !conversations.isEmpty {
            conversations.map(\.messages.count).reduce(0, +) / conversations.count
        } else {
            nil
        }

        let recentDays: Int? = if let mostRecent = conversations.first?.updatedAt {
            Calendar.current.dateComponents([.day], from: mostRecent, to: Date()).day
        } else {
            nil
        }

        var modelUsage: [String: Int] = [:]
        for conversation in conversations {
            modelUsage[conversation.model, default: 0] += 1
        }
        let total = Double(conversations.count)
        let preferredModels = modelUsage.mapValues { Double($0) / total }

        return SessionMetadata.ConversationPatterns(
            averageMessageLength: averageLength,
            averageConversationDepth: averageDepth,
            recentActivityDays: recentDays,
            preferredModels: preferredModels.isEmpty ? nil : preferredModels
        )
    }
}

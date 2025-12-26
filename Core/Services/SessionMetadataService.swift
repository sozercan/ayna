//
//  SessionMetadataService.swift
//  ayna
//
//  Created on 12/25/25.
//

import Foundation
import SwiftUI

/// Service for collecting and formatting session metadata.
/// Metadata is ephemeral and generated fresh each session.
@MainActor
final class SessionMetadataService {
    static let shared = SessionMetadataService()

    /// Whether session metadata collection is enabled.
    /// User can opt-out for privacy.
    var isEnabled: Bool {
        get { AppPreferences.storage.bool(forKey: "sessionMetadataEnabled") }
        set { AppPreferences.storage.set(newValue, forKey: "sessionMetadataEnabled") }
    }

    private init() {
        // Register default
        AppPreferences.storage.register(defaults: ["sessionMetadataEnabled": true])
    }

    /// Collects current session metadata.
    func collectMetadata() -> SessionMetadata {
        SessionMetadata(
            deviceType: currentDeviceType,
            platform: currentPlatform,
            appVersion: currentAppVersion,
            localTime: Date(),
            timezone: .current,
            isDarkMode: isDarkModeEnabled,
            conversationPatterns: nil // Computed separately if needed
        )
    }

    /// Formats metadata for context injection.
    /// Returns nil if metadata collection is disabled.
    func formattedForContext() -> String? {
        guard isEnabled else { return nil }
        return collectMetadata().formattedForContext()
    }

    // MARK: - Private Helpers

    private var currentDeviceType: SessionMetadata.DeviceType {
        #if os(macOS)
            return .desktop
        #elseif os(iOS)
            // Check if iPad
            if UIDevice.current.userInterfaceIdiom == .pad {
                return .tablet
            } else {
                return .phone
            }
        #elseif os(watchOS)
            return .watch
        #else
            return .desktop
        #endif
    }

    private var currentPlatform: SessionMetadata.Platform {
        #if os(macOS)
            return .macOS
        #elseif os(iOS)
            return .iOS
        #elseif os(watchOS)
            return .watchOS
        #else
            return .macOS
        #endif
    }

    private var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var isDarkModeEnabled: Bool {
        #if os(macOS)
            return NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        #elseif os(iOS)
            // This requires being on the main thread and having access to a window
            // For simplicity, we'll use the current trait collection
            return UITraitCollection.current.userInterfaceStyle == .dark
        #elseif os(watchOS)
            // watchOS is always dark
            return true
        #else
            return false
        #endif
    }

    /// Computes conversation patterns from recent conversations.
    /// This is an optional enhancement that analyzes user behavior.
    func computeConversationPatterns(from conversations: [Conversation]) -> SessionMetadata.ConversationPatterns? {
        guard !conversations.isEmpty else { return nil }

        // Calculate average message length
        let allUserMessages = conversations.flatMap { $0.messages.filter { $0.role == .user } }
        let averageLength: Int? = if !allUserMessages.isEmpty {
            allUserMessages.map(\.content.count).reduce(0, +) / allUserMessages.count
        } else {
            nil
        }

        // Calculate average conversation depth
        let averageDepth: Int? = if !conversations.isEmpty {
            conversations.map(\.messages.count).reduce(0, +) / conversations.count
        } else {
            nil
        }

        // Calculate recent activity
        let recentDays: Int? = if let mostRecent = conversations.first?.updatedAt {
            Calendar.current.dateComponents([.day], from: mostRecent, to: Date()).day
        } else {
            nil
        }

        // Calculate preferred models
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

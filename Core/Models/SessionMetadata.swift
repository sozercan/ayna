//
//  SessionMetadata.swift
//  ayna
//
//  Created on 12/25/25.
//

import Foundation

/// Ephemeral metadata about the current session.
/// Generated fresh each session and not persisted.
struct SessionMetadata: Codable, Sendable {
    let deviceType: DeviceType
    let platform: Platform
    let appVersion: String
    let localTime: Date
    let timezone: TimeZone
    let isDarkMode: Bool
    let conversationPatterns: ConversationPatterns?

    init(
        deviceType: DeviceType = .desktop,
        platform: Platform = .macOS,
        appVersion: String = "",
        localTime: Date = Date(),
        timezone: TimeZone = .current,
        isDarkMode: Bool = false,
        conversationPatterns: ConversationPatterns? = nil
    ) {
        self.deviceType = deviceType
        self.platform = platform
        self.appVersion = appVersion.isEmpty ? Self.currentAppVersion : appVersion
        self.localTime = localTime
        self.timezone = timezone
        self.isDarkMode = isDarkMode
        self.conversationPatterns = conversationPatterns
    }

    /// The device type category
    enum DeviceType: String, Codable, Sendable {
        case desktop
        case tablet
        case phone
        case watch

        var displayName: String {
            switch self {
            case .desktop: "Desktop"
            case .tablet: "Tablet"
            case .phone: "Phone"
            case .watch: "Watch"
            }
        }
    }

    /// The platform/OS
    enum Platform: String, Codable, Sendable {
        case macOS
        case iOS
        case watchOS

        var displayName: String {
            rawValue
        }
    }

    /// Patterns derived from the user's conversation history
    struct ConversationPatterns: Codable, Sendable {
        var averageMessageLength: Int?
        var averageConversationDepth: Int?
        var recentActivityDays: Int?
        var preferredModels: [String: Double]?

        init(
            averageMessageLength: Int? = nil,
            averageConversationDepth: Int? = nil,
            recentActivityDays: Int? = nil,
            preferredModels: [String: Double]? = nil
        ) {
            self.averageMessageLength = averageMessageLength
            self.averageConversationDepth = averageConversationDepth
            self.recentActivityDays = recentActivityDays
            self.preferredModels = preferredModels
        }
    }

    /// Gets the current app version from the bundle
    private static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// Formats the metadata for injection into the AI context.
    func formattedForContext() -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .medium
        formatter.timeZone = timezone

        var lines: [String] = [
            "Session Info:",
            "- Platform: \(platform.displayName) (\(deviceType.displayName))",
            "- Local time: \(formatter.string(from: localTime))",
            "- Timezone: \(timezone.identifier)",
            "- App version: \(appVersion)"
        ]

        if let patterns = conversationPatterns {
            if let avgLength = patterns.averageMessageLength {
                lines.append("- Average message length: ~\(avgLength) chars")
            }
            if let avgDepth = patterns.averageConversationDepth {
                lines.append("- Average conversation depth: ~\(avgDepth) messages")
            }
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - TimeZone Codable Conformance

extension TimeZone: @retroactive Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let identifier = try container.decode(String.self)
        guard let timezone = TimeZone(identifier: identifier) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid timezone identifier: \(identifier)"
                )
            )
        }
        self = timezone
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(identifier)
    }
}

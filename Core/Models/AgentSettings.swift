//
//  AgentSettings.swift
//  ayna
//

import Foundation
import SwiftUI

/// Configuration for agentic tool capabilities
struct AgentSettings: Codable, Equatable {
    /// Whether agentic tools are enabled
    var isEnabled: Bool = false

    /// Maximum depth for chained tool calls to prevent infinite loops
    var maxToolChainDepth: Int = 25

    private static let storageKey = "agentSettings"

    /// Load settings from UserDefaults
    static func load() -> AgentSettings {
        guard let data = AppPreferences.storage.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(AgentSettings.self, from: data)
        else {
            return AgentSettings()
        }
        return settings
    }

    /// Save settings to UserDefaults
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            AppPreferences.storage.set(data, forKey: Self.storageKey)
        }
    }
}

/// Observable store for agent settings, used with @Bindable in SwiftUI
@Observable
@MainActor
final class AgentSettingsStore {
    static let shared = AgentSettingsStore()

    var settings: AgentSettings {
        didSet {
            settings.save()
        }
    }

    private init() {
        settings = AgentSettings.load()
    }
}

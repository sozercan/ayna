//
//  AgentSettings.swift
//  Ayna
//
//  Settings model for agentic tool configuration.
//  Persisted via AppPreferences.
//

import Foundation

/// Settings for native agentic tools (macOS only)
struct AgentSettings: Codable, Sendable {
    /// Whether agentic tools are enabled
    var isEnabled: Bool

    /// Maximum tool chain depth (number of consecutive tool calls)
    var maxToolChainDepth: Int

    /// Default permission level for different tool categories
    var defaultPermissions: [String: PermissionLevel]

    /// Timeout for shell commands in seconds
    var commandTimeoutSeconds: Int

    /// Whether to require approval for file operations outside project
    var requireApprovalOutsideProject: Bool

    /// Whether to persist approvals across sessions
    var persistApprovals: Bool

    /// Approval timeout in seconds (0 = no timeout)
    var approvalTimeoutSeconds: Int

    /// Additional blocked command patterns (added to defaults)
    var additionalBlockedPatterns: [String]

    /// Additional allowed commands (added to defaults)
    var additionalAllowedCommands: [String]

    /// Project root path (if set)
    var projectRootPath: String?

    // MARK: - Defaults

    static let `default` = AgentSettings(
        isEnabled: true,
        maxToolChainDepth: 25,
        defaultPermissions: [
            "read_file": .automatic,
            "list_directory": .automatic,
            "search_files": .automatic,
            "write_file": .askOnce,
            "edit_file": .askOnce,
            "run_command": .askAlways
        ],
        commandTimeoutSeconds: 30,
        requireApprovalOutsideProject: true,
        persistApprovals: false,
        approvalTimeoutSeconds: 300,
        additionalBlockedPatterns: [],
        additionalAllowedCommands: [],
        projectRootPath: nil
    )

    // MARK: - Storage Key

    private static let storageKey = "agentSettings"

    // MARK: - Persistence

    /// Load settings from persistent storage
    static func load() -> AgentSettings {
        guard let data = AppPreferences.storage.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(AgentSettings.self, from: data)
        else {
            return .default
        }
        return settings
    }

    /// Save settings to persistent storage
    func save() {
        guard let data = try? JSONEncoder().encode(self) else {
            return
        }
        AppPreferences.storage.set(data, forKey: AgentSettings.storageKey)
    }

    // MARK: - Convenience

    /// Returns the permission level for a tool
    func permissionLevel(for tool: String) -> PermissionLevel {
        defaultPermissions[tool] ?? .askAlways
    }

    /// Updates the permission level for a tool
    mutating func setPermissionLevel(_ level: PermissionLevel, for tool: String) {
        defaultPermissions[tool] = level
    }
}

// MARK: - Observable Wrapper

#if os(macOS)
    /// Observable wrapper for AgentSettings for SwiftUI binding
    @Observable @MainActor
    final class AgentSettingsStore {
        static let shared = AgentSettingsStore()

        var settings: AgentSettings {
            didSet {
                settings.save()
                applyToServices()
            }
        }

        private init() {
            settings = AgentSettings.load()
            // Apply loaded settings to services on startup
            // Using Task to defer until AIService.shared is fully initialized
            Task { @MainActor in
                self.applyToServices()
            }
        }

        /// Applies current settings to the relevant services
        func applyToServices() {
            guard let builtinService = AIService.shared.builtinToolService,
                  let permissionService = AIService.shared.permissionService
            else {
                return
            }

            builtinService.isEnabled = settings.isEnabled
            builtinService.commandTimeoutSeconds = settings.commandTimeoutSeconds
            permissionService.approvalTimeoutSeconds = settings.approvalTimeoutSeconds
            permissionService.persistApprovalsAcrossSessions = settings.persistApprovals
        }

        /// Resets to default settings
        func resetToDefaults() {
            settings = .default
        }
    }
#endif

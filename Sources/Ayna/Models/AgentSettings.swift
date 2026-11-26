import Combine
import Foundation

struct AgentSettings: Codable, Sendable {
    var isEnabled: Bool

    var maxToolChainDepth: Int

    var defaultPermissions: [String: PermissionLevel]

    var commandTimeoutSeconds: Int

    var requireApprovalOutsideProject: Bool

    var persistApprovals: Bool

    var approvalTimeoutSeconds: Int

    var additionalBlockedPatterns: [String]

    var additionalAllowedCommands: [String]

    var projectRootPath: String?

    static let `default` = AgentSettings(
        isEnabled: true,
        maxToolChainDepth: 25,
        defaultPermissions: [
            "read_file": .automatic,
            "list_directory": .automatic,
            "search_files": .automatic,
            "web_fetch": .automatic,
            "write_file": .askOnce,
            "edit_file": .askOnce,
            "run_command": .askAlways,
            "git_context": .automatic,
            "project_context": .automatic,
            "update_tasks": .automatic
        ],
        commandTimeoutSeconds: 30,
        requireApprovalOutsideProject: true,
        persistApprovals: false,
        approvalTimeoutSeconds: 300,
        additionalBlockedPatterns: [],
        additionalAllowedCommands: [],
        projectRootPath: nil
    )

    private static let storageKey = "agentSettings"

    static func load() -> AgentSettings {
        guard let data = AppPreferences.storage.data(forKey: storageKey),
              var settings = try? JSONDecoder().decode(AgentSettings.self, from: data)
        else {
            return .default
        }
        settings.defaultPermissions = AgentSettings.default.defaultPermissions
            .merging(settings.defaultPermissions) { _, saved in saved }
        return settings
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else {
            return
        }
        AppPreferences.storage.set(data, forKey: AgentSettings.storageKey)
    }

    func permissionLevel(for tool: String) -> PermissionLevel {
        defaultPermissions[tool] ?? .askAlways
    }

    mutating func setPermissionLevel(_ level: PermissionLevel, for tool: String) {
        defaultPermissions[tool] = level
    }
}

#if os(macOS)
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
            Task { @MainActor in
                self.applyToServices()
            }
        }

        func applyToServices() {
            guard let builtinService = AIService.shared.builtinToolService,
                  let permissionService = AIService.shared.permissionService
            else {
                return
            }

            builtinService.apply(settings)
            permissionService.approvalTimeoutSeconds = settings.approvalTimeoutSeconds
            permissionService.persistApprovalsAcrossSessions = settings.persistApprovals

            WebFetchService.shared.permissionService = permissionService
            WebFetchService.shared.apply(settings)
        }

        func resetToDefaults() {
            settings = .default
        }
    }

    extension AgentSettingsStore: ObservableObject {}
#endif

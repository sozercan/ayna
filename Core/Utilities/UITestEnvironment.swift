import Foundation
import os

/// Handles deterministic configuration when the app is launched from UI tests.
enum UITestEnvironment {
    private static let flag = "AYNA_UI_TESTING"
    private static let launchArgument = "--ui-testing"
    private static let userDefaultsArgument = "-\(flag)"
    private static let defaultModel = "ui-test-model"

    static var isEnabled: Bool {
        let processInfo = ProcessInfo.processInfo
        if processInfo.environment[flag] == "1" { return true }
        if processInfo.arguments.contains(launchArgument) { return true }
        if processInfo.arguments.contains(userDefaultsArgument) { return true }
        // Avoid persisting UI-test mode across launches via UserDefaults.
        return false
    }

    /// Call once during app initialization to swap out side-effectful dependencies.
    @MainActor
    static func configureIfNeeded() {
        guard isEnabled else { return }

        DiagnosticsLogger.log(
            .app,
            level: .info,
            message: "🧪 UI test environment enabled"
        )

        configureUserDefaults()
        configureKeychain()
        configureOpenAIService()
        clearConversationArtifacts()
    }

    /// Conversation manager used when the app is running in UI tests.
    @MainActor
    static func makeConversationManager() -> ConversationManager {
        let store = EncryptedConversationStore(
            directoryURL: conversationDirectoryURL,
            keyIdentifier: "uitest-conversation-key",
            keychain: OpenAIService.keychain
        )
        return ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
    }

    /// Skip heavy background work (e.g., MCP connections) while UI tests run.
    static var shouldSkipMCPInitialization: Bool { isEnabled }

    private static func configureUserDefaults() {
        let suiteName = "AynaUITests.\(ProcessInfo.processInfo.processIdentifier)"
        guard let suite = UserDefaults(suiteName: suiteName) else { return }
        suite.removePersistentDomain(forName: suiteName)
        suite.synchronize()
        suite.set(true, forKey: "autoGenerateTitle")
        AppPreferences.use(suite)
    }

    @MainActor
    private static func configureKeychain() {
        OpenAIService.keychain = EphemeralKeychainStorage()
    }

    @MainActor
    private static func configureOpenAIService() {
        let service = OpenAIService.shared

        // Always ensure test model exists - add it if not present
        if !service.customModels.contains(defaultModel) {
            service.customModels.insert(defaultModel, at: 0)
        }

        service.modelProviders[defaultModel] = .openai
        service.modelEndpointTypes[defaultModel] = .chatCompletions

        // Always set selected model to test model for deterministic tests
        service.selectedModel = defaultModel
        service.apiKey = service.apiKey.isEmpty ? "ui-test-api-key" : service.apiKey

        DiagnosticsLogger.log(
            .app,
            level: .info,
            message: "🧪 Configured OpenAI service for UI tests",
            metadata: [
                "customModels": "\(service.customModels)",
                "selectedModel": service.selectedModel,
                "usableModels": "\(service.usableModels)"
            ]
        )
    }

    private static func clearConversationArtifacts() {
        try? FileManager.default.removeItem(at: conversationDirectoryURL)
    }

    private static var conversationDirectoryURL: URL {
        let directoryName = "Ayna-UITests-\(ProcessInfo.processInfo.processIdentifier)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

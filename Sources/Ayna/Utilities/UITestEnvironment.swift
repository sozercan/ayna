import Foundation
import os

enum UITestEnvironment {
    static let defaultModel = "ui-test-model"
    static let secondaryWatchModel = "ui-test-model-fast"

    static var isEnabled: Bool {
        RuntimeEnvironment.isUITesting
    }

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
        configureAIService()
        clearConversationArtifacts()
    }

    #if !os(watchOS)
        @MainActor
        static func makeConversationManager() -> ConversationManager {
            let store = EncryptedConversationStore(
                directoryURL: conversationDirectoryURL,
                keyIdentifier: "uitest-conversation-key",
                keychain: AIService.keychain
            )
            return ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        }
    #endif

    #if os(watchOS)
        @MainActor
        static func configureWatchIfNeeded(
            connectivityService: WatchConnectivityService = .shared,
            conversationStore: WatchConversationStore = .shared
        ) {
            guard isEnabled else { return }

            configureIfNeeded()

            let service = AIService.shared
            let seededModels = [defaultModel, secondaryWatchModel]
            for model in seededModels {
                if !service.customModels.contains(model) {
                    service.customModels.append(model)
                }
                service.modelProviders[model] = .openai
                service.modelEndpointTypes[model] = .chatCompletions
                if service.modelAPIKeys[model]?.isEmpty ?? true {
                    service.modelAPIKeys[model] = "ui-test-api-key"
                }
            }
            service.selectedModel = defaultModel

            connectivityService.configureForUITesting(
                availableModels: seededModels,
                selectedModel: defaultModel
            )
            conversationStore.resetForUITesting()
        }
    #endif

    static var shouldSkipMCPInitialization: Bool {
        isEnabled
    }

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
        let keychain = EphemeralKeychainStorage()
        AIService.keychain = keychain
    }

    @MainActor
    private static func configureAIService() {
        let service = AIService.shared

        if !service.customModels.contains(defaultModel) {
            service.customModels.insert(defaultModel, at: 0)
        }

        service.modelProviders[defaultModel] = .openai
        service.modelEndpointTypes[defaultModel] = .chatCompletions

        service.selectedModel = defaultModel
        if service.modelAPIKeys[defaultModel]?.isEmpty ?? true {
            service.modelAPIKeys[defaultModel] = "ui-test-api-key"
        }

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

//
//  AIService.swift
//  ayna
//
//  Created on 11/2/25.
//

// swiftlint:disable file_length
// AIService aggregates multiple provider workflows until modularization.

import Combine
import Foundation
import os

// swiftlint:disable type_body_length
// This service intentionally aggregates every provider workflow until we extract dedicated modules.

enum AIProvider: String, CaseIterable, Codable {
    case openai = "OpenAI"
    case githubModels = "GitHub Models"
    case appleIntelligence = "Apple Intelligence"
    case anthropic = "Anthropic"

    var displayName: String {
        rawValue
    }
}

enum APIEndpointType: String, CaseIterable, Codable {
    case chatCompletions = "Chat Completions"
    case responses = "Responses"
    case imageGeneration = "Image Generation"

    var displayName: String {
        rawValue
    }
}

struct RequestFlightID: Hashable, Sendable {
    private let rawValue = UUID()
}

struct RequestFlight<Handle> {
    private var id: RequestFlightID?
    private var handle: Handle?

    var isActive: Bool {
        id != nil
    }

    func owns(_ id: RequestFlightID) -> Bool {
        self.id == id
    }

    @discardableResult
    mutating func install(_ handle: Handle, id: RequestFlightID) -> Handle? {
        let previous = self.handle
        self.id = id
        self.handle = handle
        return previous
    }

    @discardableResult
    mutating func clear(ifOwnedBy id: RequestFlightID) -> Bool {
        guard owns(id) else { return false }
        self.id = nil
        handle = nil
        return true
    }

    mutating func take() -> Handle? {
        id = nil
        defer { handle = nil }
        return handle
    }

    mutating func take(ifOwnedBy id: RequestFlightID) -> Handle? {
        guard owns(id) else { return nil }
        return take()
    }
}

enum RequestFlightCheckpoint: Sendable {
    case streamCancellation
    case streamRetry
    case dataCallback
    case dataRetry
    case anthropicTerminal
    case multiModelPermitQueued
    case multiModelStart
    case multiModelCallback
}

struct RequestFlightObserver: Sendable {
    let record: @Sendable (RequestFlightCheckpoint, Bool) -> Void

    static let none = RequestFlightObserver { _, _ in }
}

/// Owner-specific cancellation token for one text request.
///
/// The token retains the logical request identity across transport retries so a
/// stale owner can never cancel a newer request that reused the same service.
@MainActor
final class AITextRequest {
    fileprivate weak var service: AIService?
    fileprivate let flightID: RequestFlightID

    fileprivate init(service: AIService, flightID: RequestFlightID) {
        self.service = service
        self.flightID = flightID
    }

    func cancel() {
        service?.cancelTextRequest(flightID)
    }
}

/// Owner-specific cancellation token for one multi-model text batch.
///
/// The batch and every child transport share one logical request identity so a
/// stale token cannot cancel a replacement batch or an unrelated foreground request.
@MainActor
final class AITextBatchRequest {
    fileprivate weak var service: AIService?
    fileprivate let flightID: RequestFlightID

    fileprivate init(service: AIService, flightID: RequestFlightID) {
        self.service = service
        self.flightID = flightID
    }

    func cancel() {
        service?.cancelTextBatchRequest(flightID)
    }
}

private final class SimulatedTextRequestHandle: @unchecked Sendable {
    private struct State: Sendable {
        var task: Task<Void, Never>?
        var isTerminal = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(_ task: Task<Void, Never>) {
        let shouldCancel = state.withLock { state -> Bool in
            guard !state.isTerminal else { return true }
            state.task = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        let task = state.withLock { state -> Task<Void, Never>? in
            guard !state.isTerminal else { return nil }
            state.isTerminal = true
            defer { state.task = nil }
            return state.task
        }
        task?.cancel()
    }

    func finish() {
        state.withLock { state in
            state.isTerminal = true
            state.task = nil
        }
    }
}

#if !os(watchOS)
    /// Owner-specific cancellation token for one image transport request.
    ///
    /// Higher-level image operations retain these tokens so replacing a view or
    /// cancelling one conversation cannot accidentally cancel another owner's work.
    @MainActor
    final class AIImageRequest {
        fileprivate weak var service: AIService?
        fileprivate let flightID: RequestFlightID

        fileprivate init(service: AIService, flightID: RequestFlightID) {
            self.service = service
            self.flightID = flightID
        }

        func cancel() {
            service?.cancelImageRequest(flightID)
        }
    }
#endif

private final class OrderedMainActorForwarder<Event: Sendable>: Sendable {
    private struct State: Sendable {
        var events: [Event] = []
        var isDraining = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let receive: @MainActor @Sendable (Event) -> Void

    init(receive: @escaping @MainActor @Sendable (Event) -> Void) {
        self.receive = receive
    }

    func enqueue(_ event: Event) {
        let shouldStart = state.withLock { state -> Bool in
            state.events.append(event)
            guard !state.isDraining else { return false }
            state.isDraining = true
            return true
        }
        guard shouldStart else { return }

        Task { @MainActor [self] in
            while let event = nextEvent() {
                receive(event)
            }
        }
    }

    private func nextEvent() -> Event? {
        state.withLock { state in
            guard !state.events.isEmpty else {
                state.isDraining = false
                return nil
            }
            return state.events.removeFirst()
        }
    }
}

private enum AnthropicFlightCallback: @unchecked Sendable {
    case chunk(String)
    case complete
    case error(Error)
    case toolRequest(id: String, name: String, arguments: [String: Any])
    case reasoning(String)
}

private enum MultiModelBatchCallback: @unchecked Sendable {
    case chunk(String)
    case complete
    case error(Error)
    case toolRequest(id: String, name: String, arguments: [String: Any])
    case reasoning(String)
}

#if !os(watchOS)
    @MainActor
    private struct AppleIntelligenceRequestHandle {
        let task: Task<Void, Never>
        let service: any AppleIntelligenceServing
        let sessionID: String

        func cancel() {
            task.cancel()
            service.clearSession(conversationId: sessionID)
        }
    }

    @MainActor
    private struct AppleIntelligenceRequestContext {
        let service: any AppleIntelligenceServing
        let messages: [Message]
        let modelName: String
        let temperature: Double?
        let stream: Bool
        let conversationID: UUID?
        let isMultiModelRequest: Bool
        let onChunk: @Sendable (String) -> Void
        let onComplete: @Sendable () -> Void
        let onError: @Sendable (Error) -> Void
    }

    private struct AppleConversationContext {
        let history: [AppleIntelligenceHistoryEntry]
        let prompt: String
        let requiresHistory: Bool
    }

    private struct AppleToolMatchPlan {
        var assistantCallIDs: [UUID: [Int: String]] = [:]
        var toolOutputIDs: [UUID: [Int: String]] = [:]
    }
#endif

struct AIServiceResponseSimulationCallbacks: Sendable {
    let onChunk: @Sendable (String) -> Void
    let onComplete: @Sendable () -> Void
}

typealias AIServiceResponseSimulator = @MainActor @Sendable (
    [Message],
    AIServiceResponseSimulationCallbacks
) -> Void

private enum MultiModelCredentialSource: Sendable {
    case githubOAuth
    case storedModelKey(oauthTokenAtPreparation: String?)
}

private struct MultiModelPreparedCredential: Sendable {
    let value: String
    let source: MultiModelCredentialSource
}

@MainActor
class AIService: ObservableObject {
    static let shared = AIService()
    static var keychain: KeychainStoring = KeychainStorage.standard

    private enum KeychainKeys {
        static let modelAPIKeys = "model_api_keys"
    }

    /// Tracks whether API keys were successfully loaded from Keychain during init.
    /// Prevents overwriting valid Keychain data when a read failure caused an empty load.
    private var keychainLoadSucceeded = false

    @Published var selectedModel: String {
        didSet {
            // Only persist on iOS/macOS
            #if !os(watchOS)
                AppPreferences.storage.set(selectedModel, forKey: "selectedModel")
            #endif
        }
    }

    // Track current task for cancellation
    private var currentTask = RequestFlight<URLSessionDataTask>()
    private var multiModelDataTasks: [String: RequestFlight<URLSessionDataTask>] = [:]
    private var currentStreamTask = RequestFlight<Task<Void, Never>>()
    private var currentNonStreamToolTask = RequestFlight<Task<Void, Never>>()
    private var multiModelNonStreamToolTasks: [String: RequestFlight<Task<Void, Never>>] = [:]
    private var currentSimulatedTextRequest = RequestFlight<SimulatedTextRequestHandle>()
    private var multiModelSimulatedTextRequests: [String: RequestFlight<SimulatedTextRequestHandle>] = [:]
    private var multiModelTask = RequestFlight<Task<Void, Never>>()
    /// Tracks individual stream tasks for each model in multi-model mode
    private var multiModelStreamTasks: [String: RequestFlight<Task<Void, Never>>] = [:]
    #if !os(watchOS)
        private var currentAppleIntelligenceTask = RequestFlight<AppleIntelligenceRequestHandle>()
        private var multiModelAppleIntelligenceTasks: [String: RequestFlight<AppleIntelligenceRequestHandle>] = [:]
        private var imageRequests: [RequestFlightID: OpenAIImageService.RequestHandle] = [:]
    #endif

    /// Holds Anthropic providers during active requests to prevent deallocation.
    private var currentAnthropicProvider = RequestFlight<any AIProviderProtocol>()
    private var multiModelAnthropicProviders: [String: RequestFlight<any AIProviderProtocol>] = [:]

    @Published var provider: AIProvider {
        didSet {
            #if !os(watchOS)
                AppPreferences.storage.set(provider.rawValue, forKey: "aiProvider")
            #endif
        }
    }

    private let openAIURL = "https://api.openai.com/v1/chat/completions"
    private let azureAPIVersion = "2025-04-01-preview"

    /// Custom URLSession with longer timeout for slow models
    private let urlSession: URLSession
    private let anthropicProviderFactory: @MainActor (URLSession) -> any AIProviderProtocol
    private let retryDelay: @Sendable (Int, Date?) async -> Void
    private let requestFlightObserver: RequestFlightObserver
    private let responseSimulator: AIServiceResponseSimulator?
    #if !os(watchOS)
        private let injectedAppleIntelligenceService: (any AppleIntelligenceServing)?
    #endif

    // Image generation service
    #if !os(watchOS)
        private let imageService: OpenAIImageService
    #endif

    // Native agentic tools (macOS only)
    #if os(macOS)
        private(set) var builtinToolService: BuiltinToolService?
        private(set) var permissionService: PermissionService?
    #endif

    @Published var customModels: [String] {
        didSet {
            #if !os(watchOS)
                AppPreferences.storage.set(customModels, forKey: "customModels")
                // iCloud sync disabled for free developer account
                // NSUbiquitousKeyValueStore.default.set(customModels, forKey: "customModels")
                // NSUbiquitousKeyValueStore.default.synchronize()
            #endif
        }
    }

    @Published var modelProviders: [String: AIProvider] {
        didSet {
            #if !os(watchOS)
                let encodedDict = modelProviders.mapValues { $0.rawValue }
                AppPreferences.storage.set(encodedDict, forKey: "modelProviders")
                // iCloud sync disabled for free developer account
                // NSUbiquitousKeyValueStore.default.set(encodedDict, forKey: "modelProviders")
                // NSUbiquitousKeyValueStore.default.synchronize()
            #endif
        }
    }

    @Published var modelEndpointTypes: [String: APIEndpointType] {
        didSet {
            #if !os(watchOS)
                let encodedDict = modelEndpointTypes.mapValues { $0.rawValue }
                AppPreferences.storage.set(encodedDict, forKey: "modelEndpointTypes")
                // iCloud sync disabled for free developer account
                // NSUbiquitousKeyValueStore.default.set(encodedDict, forKey: "modelEndpointTypes")
                // NSUbiquitousKeyValueStore.default.synchronize()
            #endif
        }
    }

    @Published var modelEndpoints: [String: String] {
        didSet {
            #if !os(watchOS)
                AppPreferences.storage.set(modelEndpoints, forKey: "modelEndpoints")
                // iCloud sync disabled for free developer account
                // NSUbiquitousKeyValueStore.default.set(modelEndpoints, forKey: "modelEndpoints")
                // NSUbiquitousKeyValueStore.default.synchronize()
            #endif
        }
    }

    @Published var modelAPIKeys: [String: String] {
        didSet {
            #if !os(watchOS)
                persistModelAPIKeys()
            #endif
        }
    }

    /// Tracks which models use GitHub OAuth
    @Published var modelUsesGitHubOAuth: [String: Bool] {
        didSet {
            #if !os(watchOS)
                let dict = modelUsesGitHubOAuth.mapValues { $0 as NSNumber }
                AppPreferences.storage.set(dict, forKey: "modelUsesGitHubOAuth")
            #endif
        }
    }

    // Web search settings (synced from iPhone on watchOS)
    #if os(watchOS)
        @Published var tavilyAPIKey: String = ""
        @Published var tavilyEnabled: Bool = false
        @Published var webSearchEnabled: Bool = false
    #endif

    /// Image generation settings
    @Published var imageSize: String {
        didSet {
            AppPreferences.storage.set(imageSize, forKey: "imageSize")
        }
    }

    @Published var imageQuality: String {
        didSet {
            AppPreferences.storage.set(imageQuality, forKey: "imageQuality")
        }
    }

    @Published var outputFormat: String {
        didSet {
            AppPreferences.storage.set(outputFormat, forKey: "outputFormat")
        }
    }

    @Published var outputCompression: Int {
        didSet {
            AppPreferences.storage.set(outputCompression, forKey: "outputCompression")
        }
    }

    enum ModelCapability {
        case chat
        case imageGeneration
    }

    #if !os(watchOS)
        private static func makeImageService(
            urlSession: URLSession,
            retryDelay: @escaping @Sendable (Int, Date?) async -> Void
        ) -> OpenAIImageService {
            OpenAIImageService(
                urlSession: urlSession,
                retryDelay: { attempt in await retryDelay(attempt, nil) }
            )
        }
    #endif

    init(
        urlSession: URLSession? = nil,
        anthropicProviderFactory: @escaping @MainActor (URLSession) -> any AIProviderProtocol = {
            AnthropicProvider(urlSession: $0)
        },
        retryDelay: @escaping @Sendable (Int, Date?) async -> Void = { attempt, retryAfterDate in
            await AIRetryPolicy.wait(for: attempt, retryAfterDate: retryAfterDate)
        },
        requestFlightObserver: RequestFlightObserver = .none,
        responseSimulator: AIServiceResponseSimulator? = nil,
        appleIntelligenceService: (any AppleIntelligenceServing)? = nil
    ) {
        self.anthropicProviderFactory = anthropicProviderFactory
        self.retryDelay = retryDelay
        self.requestFlightObserver = requestFlightObserver
        self.responseSimulator = responseSimulator
        #if !os(watchOS)
            injectedAppleIntelligenceService = appleIntelligenceService
        #endif

        if let session = urlSession {
            self.urlSession = session
            #if !os(watchOS)
                imageService = Self.makeImageService(urlSession: session, retryDelay: retryDelay)
            #endif
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 120 // 2 minutes
            config.timeoutIntervalForResource = 300 // 5 minutes
            self.urlSession = URLSession(configuration: config)
            #if !os(watchOS)
                imageService = Self.makeImageService(urlSession: self.urlSession, retryDelay: retryDelay)
            #endif
        }

        // Check if running in UI test mode - configure test model early
        // Multiple checks because different platforms/test runners set flags differently
        let isUITesting = ProcessInfo.processInfo.environment["AYNA_UI_TESTING"] == "1" ||
            ProcessInfo.processInfo.arguments.contains("--ui-testing") ||
            ProcessInfo.processInfo.arguments.contains("-AYNA_UI_TESTING") ||
            UserDefaults.standard.bool(forKey: "AYNA_UI_TESTING")

        // Load custom models first
        var loadedCustomModels: [String] = if let savedModels = AppPreferences.storage.array(forKey: "customModels") as? [String] {
            savedModels
        } else {
            []
        }

        // Ensure test model exists during UI testing
        let testModelName = "ui-test-model"
        if isUITesting, !loadedCustomModels.contains(testModelName) {
            loadedCustomModels.insert(testModelName, at: 0)
        }
        customModels = loadedCustomModels

        // Load model providers mapping
        let loadedProviders: [String: AIProvider]
        if let savedProviders = AppPreferences.storage.dictionary(forKey: "modelProviders")
            as? [String: String]
        {
            let mapped = savedProviders.compactMapValues { AIProvider(rawValue: $0) }
            let droppedProviders = savedProviders.keys.filter { mapped[$0] == nil }
            if !droppedProviders.isEmpty {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .error,
                    message: "Dropped unrecognized provider mappings during load — models may appear reset",
                    metadata: ["droppedModels": droppedProviders.joined(separator: ", "),
                               "rawValues": droppedProviders.compactMap { savedProviders[$0] }.joined(separator: ", ")]
                )
            }
            loadedProviders = mapped
        } else {
            // Default all initial models to OpenAI
            loadedProviders = Dictionary(
                uniqueKeysWithValues: loadedCustomModels.map { ($0, AIProvider.openai) }
            )
        }

        // Ensure test model has a provider during UI testing
        var updatedProviders = loadedProviders
        if isUITesting, updatedProviders[testModelName] == nil {
            updatedProviders[testModelName] = .openai
        }
        modelProviders = updatedProviders

        // Load model endpoint types mapping
        let loadedEndpointTypes: [String: APIEndpointType]
        if let savedEndpointTypes = AppPreferences.storage.dictionary(forKey: "modelEndpointTypes")
            as? [String: String]
        {
            let mapped = savedEndpointTypes.compactMapValues { APIEndpointType(rawValue: $0) }
            let droppedTypes = savedEndpointTypes.keys.filter { mapped[$0] == nil }
            if !droppedTypes.isEmpty {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .error,
                    message: "Dropped unrecognized endpoint type mappings during load — models may appear reset",
                    metadata: ["droppedModels": droppedTypes.joined(separator: ", "),
                               "rawValues": droppedTypes.compactMap { savedEndpointTypes[$0] }.joined(separator: ", ")]
                )
            }
            loadedEndpointTypes = mapped
        } else {
            // Default all models to Chat Completions
            loadedEndpointTypes = Dictionary(
                uniqueKeysWithValues: loadedCustomModels.map { ($0, APIEndpointType.chatCompletions) }
            )
        }

        // Ensure test model has an endpoint type during UI testing
        var updatedEndpointTypes = loadedEndpointTypes
        if isUITesting, updatedEndpointTypes[testModelName] == nil {
            updatedEndpointTypes[testModelName] = .chatCompletions
        }
        modelEndpointTypes = updatedEndpointTypes

        // Load custom endpoints mapping
        let loadedEndpoints: [String: String] = if let savedEndpoints = AppPreferences.storage.dictionary(forKey: "modelEndpoints")
            as? [String: String]
        {
            savedEndpoints
        } else {
            [:]
        }
        modelEndpoints = loadedEndpoints

        // Load per-model API keys
        let (loadedAPIKeys, loadSuccess) = AIService.loadModelAPIKeys()
        var mutableAPIKeys = loadedAPIKeys

        // Ensure test model has an API key during UI testing
        if isUITesting, mutableAPIKeys[testModelName]?.isEmpty ?? true {
            mutableAPIKeys[testModelName] = "ui-test-api-key"
        }
        modelAPIKeys = mutableAPIKeys
        keychainLoadSucceeded = loadSuccess

        // Load GitHub OAuth flags for models
        if let savedOAuthFlags = AppPreferences.storage.dictionary(forKey: "modelUsesGitHubOAuth") as? [String: NSNumber] {
            modelUsesGitHubOAuth = savedOAuthFlags.mapValues { $0.boolValue }
        } else {
            modelUsesGitHubOAuth = [:]
        }

        // Load selected model, ensure it exists in custom models
        let savedSelectedModel = AppPreferences.storage.string(forKey: "selectedModel") ?? ""
        if isUITesting {
            // Always use test model for UI tests
            selectedModel = testModelName
        } else if loadedCustomModels.contains(savedSelectedModel) {
            selectedModel = savedSelectedModel
        } else if let firstModel = loadedCustomModels.first {
            selectedModel = firstModel
        } else {
            selectedModel = ""
        }

        // Initialize provider
        if let providerString = AppPreferences.storage.string(forKey: "aiProvider"),
           let savedProvider = AIProvider(rawValue: providerString)
        {
            provider = savedProvider
        } else {
            provider = .openai
        }

        // Initialize image generation settings
        imageSize = AppPreferences.storage.string(forKey: "imageSize") ?? "1024x1024"
        imageQuality = AppPreferences.storage.string(forKey: "imageQuality") ?? "medium"
        outputFormat = AppPreferences.storage.string(forKey: "outputFormat") ?? "png"
        outputCompression =
            AppPreferences.storage.integer(forKey: "outputCompression") == 0
                ? 100 : AppPreferences.storage.integer(forKey: "outputCompression")

        // iCloud sync disabled for free developer account
        // setupiCloudSync()

        // Initialize native agentic tools (macOS only)
        #if os(macOS)
            let permService = PermissionService()
            self.permissionService = permService
            self.builtinToolService = BuiltinToolService(
                permissionService: permService,
                projectRoot: nil // Will be set via configureProjectRoot()
            )
            // Trigger AgentSettingsStore initialization to apply saved settings
            _ = AgentSettingsStore.shared
        #endif
    }

    // Configures the project root for agentic tools (macOS only)
    #if os(macOS)
        func configureProjectRoot(_ url: URL?) {
            guard let permService = permissionService else { return }
            builtinToolService = BuiltinToolService(
                permissionService: permService,
                projectRoot: url
            )
        }
    #endif

    private func persistModelAPIKeys() {
        guard keychainLoadSucceeded else {
            DiagnosticsLogger.log(
                .aiService,
                level: .error,
                message: "Skipping API key persistence — Keychain load failed at init, refusing to overwrite potentially valid data"
            )
            return
        }
        do {
            try AIService.storeModelAPIKeys(modelAPIKeys)
        } catch {
            DiagnosticsLogger.log(
                .aiService,
                level: .error,
                message: "Failed to persist model API keys",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    private static func loadModelAPIKeys() -> (keys: [String: String], success: Bool) {
        do {
            if let data = try keychain.data(for: KeychainKeys.modelAPIKeys) {
                do {
                    let keys = try JSONDecoder().decode([String: String].self, from: data)
                    DiagnosticsLogger.log(
                        .aiService,
                        level: .info,
                        message: "Loaded model API keys from Keychain",
                        metadata: ["modelCount": "\(keys.count)", "models": keys.keys.joined(separator: ", ")]
                    )
                    return (keys, true)
                } catch {
                    DiagnosticsLogger.log(
                        .aiService,
                        level: .error,
                        message: "Failed to decode model API keys from Keychain",
                        metadata: ["error": error.localizedDescription]
                    )
                }
            } else {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .info,
                    message: "No model API keys found in Keychain (first launch or code signature changed)"
                )
                // No data in Keychain is a valid state (first launch), not a failure
                return ([:], true)
            }
        } catch {
            DiagnosticsLogger.log(
                .aiService,
                level: .error,
                message: "Failed to read model API keys from Keychain",
                metadata: ["error": error.localizedDescription]
            )
        }
        return ([:], false)
    }

    private static func storeModelAPIKeys(_ dictionary: [String: String]) throws {
        if dictionary.isEmpty {
            DiagnosticsLogger.log(
                .aiService,
                level: .info,
                message: "Removing model API keys from Keychain (dictionary is empty)"
            )
            try keychain.removeValue(for: KeychainKeys.modelAPIKeys)
            return
        }

        let data = try JSONEncoder().encode(dictionary)
        try keychain.setData(data, for: KeychainKeys.modelAPIKeys)
        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: "Stored model API keys to Keychain",
            metadata: ["modelCount": "\(dictionary.count)", "models": dictionary.keys.joined(separator: ", ")]
        )
    }

    private func normalizedModelName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private func customEndpoint(for modelName: String?) -> (endpoint: String, model: String)? {
        guard let normalizedName = normalizedModelName(modelName),
              let endpoint = modelEndpoints[normalizedName]?
              .trimmingCharacters(in: .whitespacesAndNewlines),
              !endpoint.isEmpty
        else {
            return nil
        }

        return (endpoint, normalizedName)
    }

    private func isAzureEndpoint(_ endpoint: String?) -> Bool {
        OpenAIEndpointResolver.isAzureEndpoint(endpoint)
    }

    /// Get API key for a specific model.
    /// For GitHub Models with OAuth, returns the OAuth token.
    /// Returns empty string if no key is configured for the model.
    func getAPIKey(for model: String?) -> String {
        guard let model else { return "" }

        // Check if this model uses GitHub OAuth
        let usesOAuth = modelUsesGitHubOAuth[model] == true
        let isGitHubModel = modelProviders[model] == .githubModels

        DiagnosticsLogger.log(
            .aiService,
            level: .debug,
            message: "🔑 Getting API key for model",
            metadata: [
                "model": model,
                "isGitHubModel": "\(isGitHubModel)",
                "usesOAuth": "\(usesOAuth)",
                "isAuthenticated": "\(GitHubOAuthService.shared.isAuthenticated)"
            ]
        )

        // For GitHub Models, always try OAuth token first if authenticated
        if isGitHubModel {
            if GitHubOAuthService.shared.isAuthenticated,
               let token = GitHubOAuthService.shared.getAccessToken(),
               !token.isEmpty
            {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .debug,
                    message: "🔑 Using GitHub OAuth token",
                    metadata: ["tokenPrefix": String(token.prefix(10)) + "..."]
                )
                return token
            } else {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .info,
                    message: "⚠️ GitHub OAuth not available, using stored API key"
                )
            }
        }

        return modelAPIKeys[model] ?? ""
    }

    /// Async version of getAPIKey that ensures the token is valid before returning.
    /// For GitHub Models with OAuth, this will refresh the token if it's expiring soon.
    /// Use this for critical API requests where you can await.
    /// Returns empty string if no key is configured for the model.
    func getValidAPIKey(for model: String?) async throws -> String {
        guard let model else { return "" }

        let isGitHubModel = modelProviders[model] == .githubModels

        // For GitHub Models, use the async method that handles refresh deduplication
        if isGitHubModel, GitHubOAuthService.shared.isAuthenticated {
            do {
                let token = try await GitHubOAuthService.shared.getValidAccessToken()
                DiagnosticsLogger.log(
                    .aiService,
                    level: .debug,
                    message: "🔑 Using validated GitHub OAuth token",
                    metadata: ["tokenPrefix": String(token.prefix(10)) + "..."]
                )
                return token
            } catch {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .error,
                    message: "❌ Failed to get valid GitHub token: \(error.localizedDescription)"
                )
                // Fall back to stored API key
            }
        }

        return modelAPIKeys[model] ?? ""
    }

    private func prepareGitHubCredential(for model: String) async throws -> MultiModelPreparedCredential {
        if GitHubOAuthService.shared.isAuthenticated {
            do {
                let accessToken = try await GitHubOAuthService.shared.getValidAccessToken()
                guard !accessToken.isEmpty else {
                    throw AynaError.missingAPIKey(provider: AIProvider.githubModels.displayName)
                }
                return MultiModelPreparedCredential(value: accessToken, source: .githubOAuth)
            } catch {
                if let storedKey = modelAPIKeys[model], !storedKey.isEmpty {
                    return MultiModelPreparedCredential(
                        value: storedKey,
                        source: .storedModelKey(
                            oauthTokenAtPreparation: GitHubOAuthService.shared.getAccessToken()
                        )
                    )
                }
                throw error
            }
        }

        guard let storedKey = modelAPIKeys[model], !storedKey.isEmpty else {
            throw AynaError.missingAPIKey(provider: AIProvider.githubModels.displayName)
        }
        return MultiModelPreparedCredential(
            value: storedKey,
            source: .storedModelKey(oauthTokenAtPreparation: nil)
        )
    }

    private func isCurrentGitHubCredential(
        _ credential: MultiModelPreparedCredential,
        model: String
    ) -> Bool {
        switch credential.source {
        case .githubOAuth:
            return GitHubOAuthService.shared.isAuthenticated &&
                GitHubOAuthService.shared.isCurrentAccessTokenValid(credential.value)
        case let .storedModelKey(oauthTokenAtPreparation):
            let currentOAuthToken = GitHubOAuthService.shared.isAuthenticated
                ? GitHubOAuthService.shared.getAccessToken()
                : nil
            return modelAPIKeys[model] == credential.value &&
                currentOAuthToken == oauthTokenAtPreparation
        }
    }

    private func getAPIURL(deploymentName: String? = nil, provider: AIProvider? = nil) throws -> String {
        let effectiveProvider = provider ?? self.provider
        let modelName = deploymentName ?? selectedModel
        let endpointInfo = customEndpoint(for: modelName)

        let config = OpenAIEndpointResolver.EndpointConfig(
            modelName: modelName,
            provider: effectiveProvider,
            customEndpoint: endpointInfo?.endpoint,
            azureAPIVersion: azureAPIVersion
        )

        return try OpenAIEndpointResolver.chatCompletionsURL(for: config)
    }

    private func getResponsesAPIURL(deploymentName: String? = nil, provider: AIProvider? = nil) throws -> String {
        let effectiveProvider = provider ?? self.provider
        let modelName = deploymentName ?? selectedModel
        let endpointInfo = customEndpoint(for: modelName)

        let config = OpenAIEndpointResolver.EndpointConfig(
            modelName: modelName,
            provider: effectiveProvider,
            customEndpoint: endpointInfo?.endpoint,
            azureAPIVersion: azureAPIVersion
        )

        return try OpenAIEndpointResolver.responsesURL(for: config)
    }

    func getModelCapability(_ model: String) -> ModelCapability {
        // Check the endpoint type setting for this model
        if let endpointType = modelEndpointTypes[model] {
            switch endpointType {
            case .imageGeneration:
                return .imageGeneration
            case .chatCompletions, .responses:
                return .chat
            }
        }
        // Default to chat if no setting found
        return .chat
    }

    fileprivate func cancelTextRequest(_ flightID: RequestFlightID) {
        let dataTask = currentTask.take(ifOwnedBy: flightID)
        let streamTask = currentStreamTask.take(ifOwnedBy: flightID)
        let nonStreamToolTask = currentNonStreamToolTask.take(ifOwnedBy: flightID)
        let simulatedRequest = currentSimulatedTextRequest.take(ifOwnedBy: flightID)
        let anthropicProvider = currentAnthropicProvider.take(ifOwnedBy: flightID)

        let multiDataTaskModels = multiModelDataTasks.compactMap { model, flight in
            flight.owns(flightID) ? model : nil
        }
        let multiDataTasks = multiDataTaskModels.compactMap { model -> URLSessionDataTask? in
            var ownedFlight = multiModelDataTasks.removeValue(forKey: model)
            return ownedFlight?.take(ifOwnedBy: flightID)
        }
        let multiStreamTaskModels = multiModelStreamTasks.compactMap { model, flight in
            flight.owns(flightID) ? model : nil
        }
        let multiStreamTasks = multiStreamTaskModels.compactMap { model -> Task<Void, Never>? in
            var ownedFlight = multiModelStreamTasks.removeValue(forKey: model)
            return ownedFlight?.take(ifOwnedBy: flightID)
        }
        let multiNonStreamToolTaskModels = multiModelNonStreamToolTasks.compactMap { model, flight in
            flight.owns(flightID) ? model : nil
        }
        let multiNonStreamToolTasks = multiNonStreamToolTaskModels.compactMap { model -> Task<Void, Never>? in
            var ownedFlight = multiModelNonStreamToolTasks.removeValue(forKey: model)
            return ownedFlight?.take(ifOwnedBy: flightID)
        }
        let multiSimulatedRequestModels = multiModelSimulatedTextRequests.compactMap { model, flight in
            flight.owns(flightID) ? model : nil
        }
        let multiSimulatedRequests = multiSimulatedRequestModels.compactMap { model -> SimulatedTextRequestHandle? in
            var ownedFlight = multiModelSimulatedTextRequests.removeValue(forKey: model)
            return ownedFlight?.take(ifOwnedBy: flightID)
        }
        let multiAnthropicProviderModels = multiModelAnthropicProviders.compactMap { model, flight in
            flight.owns(flightID) ? model : nil
        }
        let multiAnthropicProviders = multiAnthropicProviderModels.compactMap { model -> (any AIProviderProtocol)? in
            var ownedFlight = multiModelAnthropicProviders.removeValue(forKey: model)
            return ownedFlight?.take(ifOwnedBy: flightID)
        }

        #if !os(watchOS)
            let appleTask = currentAppleIntelligenceTask.take(ifOwnedBy: flightID)
            let multiAppleTaskModels = multiModelAppleIntelligenceTasks.compactMap { model, flight in
                flight.owns(flightID) ? model : nil
            }
            let multiAppleTasks = multiAppleTaskModels.compactMap { model -> AppleIntelligenceRequestHandle? in
                var ownedFlight = multiModelAppleIntelligenceTasks.removeValue(forKey: model)
                return ownedFlight?.take(ifOwnedBy: flightID)
            }
        #endif

        dataTask?.cancel()
        multiDataTasks.forEach { $0.cancel() }
        streamTask?.cancel()
        multiStreamTasks.forEach { $0.cancel() }
        nonStreamToolTask?.cancel()
        multiNonStreamToolTasks.forEach { $0.cancel() }
        simulatedRequest?.cancel()
        multiSimulatedRequests.forEach { $0.cancel() }
        anthropicProvider?.cancelRequest()
        multiAnthropicProviders.forEach { $0.cancelRequest() }
        #if !os(watchOS)
            appleTask?.cancel()
            multiAppleTasks.forEach { $0.cancel() }
        #endif
    }

    fileprivate func cancelTextBatchRequest(_ flightID: RequestFlightID) {
        guard let batchTask = multiModelTask.take(ifOwnedBy: flightID) else { return }

        // Fence queued runners before cancelling children that may release shared permits.
        batchTask.cancel()
        cancelTextRequest(flightID)
    }

    private func cancelForegroundNonStreamToolRequest() {
        guard currentNonStreamToolTask.isActive else { return }
        let dataTask = currentTask.take()
        let toolTask = currentNonStreamToolTask.take()
        dataTask?.cancel()
        toolTask?.cancel()
    }

    func cancelCurrentRequest(includeImageRequests: Bool = true) {
        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: "Canceling current request"
        )

        let dataTask = currentTask.take()
        let multiModelBatchTask = multiModelTask.take()
        let multiDataTasks = multiModelDataTasks.compactMap { model, flight -> (String, URLSessionDataTask)? in
            var flight = flight
            return flight.take().map { (model, $0) }
        }
        multiModelDataTasks.removeAll()
        let streamTask = currentStreamTask.take()
        let nonStreamToolTask = currentNonStreamToolTask.take()
        let multiNonStreamToolTasks = multiModelNonStreamToolTasks.compactMap { _, flight -> Task<Void, Never>? in
            var flight = flight
            return flight.take()
        }
        multiModelNonStreamToolTasks.removeAll()
        let simulatedRequest = currentSimulatedTextRequest.take()
        let multiSimulatedRequests = multiModelSimulatedTextRequests.compactMap { _, flight -> SimulatedTextRequestHandle? in
            var flight = flight
            return flight.take()
        }
        multiModelSimulatedTextRequests.removeAll()
        let multiStreamTasks = multiModelStreamTasks.compactMap { model, flight -> (String, Task<Void, Never>)? in
            var flight = flight
            return flight.take().map { (model, $0) }
        }
        multiModelStreamTasks.removeAll()
        let anthropicProvider = currentAnthropicProvider.take()
        let multiAnthropicProviders = multiModelAnthropicProviders.compactMap { _, flight -> (any AIProviderProtocol)? in
            var flight = flight
            return flight.take()
        }
        multiModelAnthropicProviders.removeAll()
        #if !os(watchOS)
            let appleTask = currentAppleIntelligenceTask.take()
            let multiAppleTasks = multiModelAppleIntelligenceTasks.compactMap { _, flight -> AppleIntelligenceRequestHandle? in
                var flight = flight
                return flight.take()
            }
            multiModelAppleIntelligenceTasks.removeAll()
            let imageRequestHandles: [OpenAIImageService.RequestHandle]
            if includeImageRequests {
                imageRequestHandles = Array(imageRequests.values)
                imageRequests.removeAll()
            } else {
                imageRequestHandles = []
            }
        #endif

        // Fence queued multi-model starts before active handles can release shared permits.
        multiModelBatchTask?.cancel()
        dataTask?.cancel()
        for (model, task) in multiDataTasks {
            task.cancel()
            DiagnosticsLogger.log(
                .aiService,
                level: .info,
                message: "Cancelled multi-model data task",
                metadata: ["model": model]
            )
        }
        streamTask?.cancel()
        nonStreamToolTask?.cancel()
        multiNonStreamToolTasks.forEach { $0.cancel() }
        simulatedRequest?.cancel()
        multiSimulatedRequests.forEach { $0.cancel() }
        for (model, task) in multiStreamTasks {
            task.cancel()
            DiagnosticsLogger.log(
                .aiService,
                level: .info,
                message: "Cancelled multi-model stream task",
                metadata: ["model": model]
            )
        }
        anthropicProvider?.cancelRequest()
        multiAnthropicProviders.forEach { $0.cancelRequest() }
        #if !os(watchOS)
            appleTask?.cancel()
            multiAppleTasks.forEach { $0.cancel() }
            imageRequestHandles.forEach { $0.cancel() }
        #endif
        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: "Request cancellation initiated"
        )
    }

    #if !os(watchOS)
        /// Generates an image from a text prompt.
        /// Delegates to OpenAIImageService for the actual network request.
        @discardableResult
        func generateImage(
            prompt: String,
            model: String? = nil,
            onComplete: @escaping @Sendable (Data) -> Void,
            onError: @escaping @Sendable (Error) -> Void,
            attempt: Int = 0
        ) -> AIImageRequest? {
            let requestModel = (model ?? selectedModel).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requestModel.isEmpty else {
                onError(AIError.missingModel)
                return nil
            }

            let effectiveProvider = modelProviders[requestModel] ?? provider
            let endpointInfo = customEndpoint(for: requestModel)

            let requestConfig = OpenAIImageService.RequestConfig(
                model: requestModel,
                apiKey: getAPIKey(for: requestModel),
                provider: effectiveProvider,
                customEndpoint: endpointInfo?.endpoint,
                azureAPIVersion: azureAPIVersion
            )

            let imageConfig = OpenAIImageService.ImageConfig(
                size: imageSize,
                quality: imageQuality,
                outputFormat: outputFormat,
                outputCompression: outputCompression
            )

            let flightID = RequestFlightID()
            let requestHandle = OpenAIImageService.RequestHandle()
            imageRequests[flightID] = requestHandle

            imageService.generateImage(
                prompt: prompt,
                requestConfig: requestConfig,
                imageConfig: imageConfig,
                requestHandle: requestHandle,
                onComplete: { [weak self] data in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.finishImageRequest(flightID, handle: requestHandle)
                        else {
                            return
                        }
                        onComplete(data)
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.finishImageRequest(flightID, handle: requestHandle)
                        else {
                            return
                        }
                        onError(error)
                    }
                },
                attempt: attempt
            )
            return AIImageRequest(service: self, flightID: flightID)
        }

        /// Edits an image based on a prompt and source image.
        /// Delegates to OpenAIImageService for the actual network request.
        @discardableResult
        func editImage(
            prompt: String,
            sourceImage: Data,
            model: String? = nil,
            onComplete: @escaping @Sendable (Data) -> Void,
            onError: @escaping @Sendable (Error) -> Void
        ) -> AIImageRequest? {
            let requestModel = (model ?? selectedModel).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requestModel.isEmpty else {
                onError(AIError.missingModel)
                return nil
            }

            let effectiveProvider = modelProviders[requestModel] ?? provider
            let endpointInfo = customEndpoint(for: requestModel)

            let requestConfig = OpenAIImageService.RequestConfig(
                model: requestModel,
                apiKey: getAPIKey(for: requestModel),
                provider: effectiveProvider,
                customEndpoint: endpointInfo?.endpoint,
                azureAPIVersion: azureAPIVersion
            )

            let imageConfig = OpenAIImageService.ImageConfig(
                size: imageSize,
                quality: imageQuality,
                outputFormat: outputFormat,
                outputCompression: outputCompression
            )

            let flightID = RequestFlightID()
            let requestHandle = OpenAIImageService.RequestHandle()
            imageRequests[flightID] = requestHandle

            imageService.editImage(
                prompt: prompt,
                sourceImage: sourceImage,
                requestConfig: requestConfig,
                imageConfig: imageConfig,
                requestHandle: requestHandle,
                onComplete: { [weak self] data in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.finishImageRequest(flightID, handle: requestHandle)
                        else {
                            return
                        }
                        onComplete(data)
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.finishImageRequest(flightID, handle: requestHandle)
                        else {
                            return
                        }
                        onError(error)
                    }
                }
            )
            return AIImageRequest(service: self, flightID: flightID)
        }

        fileprivate func cancelImageRequest(_ flightID: RequestFlightID) {
            guard let requestHandle = imageRequests.removeValue(forKey: flightID) else { return }
            requestHandle.cancel()
        }

        private func finishImageRequest(
            _ flightID: RequestFlightID,
            handle: OpenAIImageService.RequestHandle
        ) -> Bool {
            guard imageRequests[flightID] === handle else { return false }
            imageRequests.removeValue(forKey: flightID)
            handle.finish()
            return true
        }
    #endif

    // MARK: - Helper Methods for sendMessage

    private func validateProviderSettings(for provider: AIProvider, model: String?) throws {
        guard requiresAPIKey(for: provider, model: model) else { return }

        if !isAPIKeyConfigured(for: provider, model: model) {
            throw AynaError.missingAPIKey(provider: provider.displayName)
        }
    }

    /// Checks if GitHub Models rate limit is currently blocking requests for the given access token.
    /// Returns an error message if rate-limited, nil if requests can proceed.
    private func checkGitHubModelsRateLimit(accessToken: String) -> String? {
        guard !accessToken.isEmpty else { return nil }
        let oauthService = GitHubOAuthService.shared

        // Check if we have an active retry-after from a previous 429/403
        if let retryAfter = oauthService.retryAfterDate(forAccessToken: accessToken), retryAfter > Date() {
            let secondsRemaining = Int(retryAfter.timeIntervalSinceNow)
            if secondsRemaining > 60 {
                let minutesRemaining = secondsRemaining / 60
                return "Rate limited. Please wait \(minutesRemaining) minute\(minutesRemaining == 1 ? "" : "s")."
            } else if secondsRemaining > 0 {
                return "Rate limited. Please wait \(secondsRemaining) second\(secondsRemaining == 1 ? "" : "s")."
            }
        }

        // Check if rate limit is exhausted
        if let rateLimitInfo = oauthService.rateLimitInfo(forAccessToken: accessToken), rateLimitInfo.isExhausted {
            return "Rate limit exhausted. Resets \(rateLimitInfo.formattedReset)."
        }

        return nil
    }

    @discardableResult
    func sendMessage( // swiftlint:disable:this function_body_length
        messages: [Message],
        model: String? = nil,
        temperature: Double? = nil,
        stream: Bool = true,
        tools: [[String: Any]]? = nil,
        conversationId: UUID? = nil,
        isMultiModelRequest: Bool = false,
        onChunk: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onToolCall: (@Sendable (String, String, [String: Any]) async -> String)? = nil,
        onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)? = nil,
        onReasoning: (@Sendable (String) -> Void)? = nil,
        preparedAPIKey: String? = nil,
        requestFlightID: RequestFlightID? = nil
    ) -> AITextRequest {
        let flightID = requestFlightID ?? RequestFlightID()
        let requestHandle = AITextRequest(service: self, flightID: flightID)
        let requestModel = (model ?? selectedModel).trimmingCharacters(in: .whitespacesAndNewlines)

        if !isMultiModelRequest {
            cancelForegroundNonStreamToolRequest()
        }

        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: "📤 sendMessage called",
            metadata: [
                "model": requestModel,
                "messagesCount": "\(messages.count)",
                "stream": "\(stream)",
                "hasTools": "\(tools != nil)",
                "toolCount": "\(tools?.count ?? 0)"
            ]
        )

        if let responseSimulator {
            let simulatedRequest = beginSimulatedTextRequest(
                flightID: flightID,
                isMultiModelRequest: isMultiModelRequest,
                modelName: requestModel
            )
            responseSimulator(
                messages,
                ownedSimulationCallbacks(
                    flightID: flightID,
                    isMultiModelRequest: isMultiModelRequest,
                    modelName: requestModel,
                    requestHandle: simulatedRequest,
                    onChunk: onChunk,
                    onComplete: onComplete
            )
            )
            return requestHandle
        }

        // Mock response for UI tests on macOS and iOS (UITestEnvironment not available on watchOS)
        #if !os(watchOS)
            if UITestEnvironment.isEnabled {
                simulateUITestResponse(
                    messages: messages,
                    stream: stream,
                    flightID: flightID,
                    isMultiModelRequest: isMultiModelRequest,
                    modelName: requestModel,
                    onChunk: onChunk,
                    onComplete: onComplete
                )
                return requestHandle
            }
        #endif

        guard !requestModel.isEmpty else {
            DiagnosticsLogger.log(
                .aiService,
                level: .error,
                message: "❌ Model is empty"
            )
            onError(AIError.missingModel)
            return requestHandle
        }
        let effectiveProvider = modelProviders[requestModel] ?? provider
        let endpointInfo = customEndpoint(for: requestModel)
        let usesAzureEndpoint = endpointInfo.map { isAzureEndpoint($0.endpoint) } ?? false

        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: "📤 Provider resolved",
            metadata: [
                "model": requestModel,
                "provider": effectiveProvider.rawValue,
                "hasCustomEndpoint": "\(endpointInfo != nil)",
                "isAzure": "\(usesAzureEndpoint)"
            ]
        )

        // Handle Apple Intelligence separately
        #if !os(watchOS)
            if effectiveProvider == .appleIntelligence {
                if let service = injectedAppleIntelligenceService {
                    handleAppleIntelligenceRequest(AppleIntelligenceRequestContext(
                        service: service,
                        messages: messages,
                        modelName: requestModel,
                        temperature: temperature,
                        stream: stream,
                        conversationID: conversationId,
                        isMultiModelRequest: isMultiModelRequest,
                        onChunk: onChunk,
                        onComplete: onComplete,
                        onError: onError
                    ), flightID: flightID)
                } else if #available(macOS 26.0, iOS 26.0, *) {
                    handleAppleIntelligenceRequest(AppleIntelligenceRequestContext(
                        service: AppleIntelligenceService.shared,
                        messages: messages,
                        modelName: requestModel,
                        temperature: temperature,
                        stream: stream,
                        conversationID: conversationId,
                        isMultiModelRequest: isMultiModelRequest,
                        onChunk: onChunk,
                        onComplete: onComplete,
                        onError: onError
                    ), flightID: flightID)
                } else {
                    onError(AIError.apiError("Apple Intelligence requires macOS 26.0 or iOS 26.0 or later"))
                }
                return requestHandle
            }
        #else
            // Apple Intelligence is not available on watchOS
            if effectiveProvider == .appleIntelligence {
                onError(AIError.apiError("Apple Intelligence is not available on Apple Watch"))
                return requestHandle
            }
        #endif

        // Handle Anthropic provider separately
        if effectiveProvider == .anthropic {
            let anthropicCallbacks = AIProviderStreamCallbacks(
                onChunk: onChunk,
                onComplete: onComplete,
                onError: onError,
                onToolCallRequested: onToolCallRequested,
                onReasoning: onReasoning
            )
            handleAnthropicRequest(
                messages: messages,
                model: requestModel,
                stream: stream,
                tools: tools,
                conversationId: conversationId,
                isMultiModelRequest: isMultiModelRequest,
                callbacks: anthropicCallbacks,
                flightID: flightID
            )
            return requestHandle
        }

        // Validate provider settings
        do {
            try validateProviderSettings(for: effectiveProvider, model: requestModel)
        } catch {
            onError(error)
            return requestHandle
        }

        let modelAPIKey = preparedAPIKey ?? getAPIKey(for: requestModel)

        // Check GitHub Models rate limit before making request
        if effectiveProvider == .githubModels {
            if let rateLimitError = checkGitHubModelsRateLimit(accessToken: modelAPIKey) {
                onError(AIError.apiError(rateLimitError))
                return requestHandle
            }
        }

        // Check if this model should use the responses API (not supported for GitHub Models)
        let endpointType = modelEndpointTypes[requestModel] ?? .chatCompletions
        if endpointType == .responses {
            if effectiveProvider == .githubModels {
                onError(AIError.apiError("GitHub Models does not support the Responses API endpoint"))
                return requestHandle
            }
            responsesAPIRequest(
                messages: messages,
                model: requestModel,
                conversationId: conversationId,
                onChunk: onChunk,
                onComplete: onComplete,
                onError: onError,
                onToolCallRequested: onToolCallRequested,
                onReasoning: onReasoning,
                isMultiModelRequest: isMultiModelRequest,
                initialFlightID: flightID
            )
            return requestHandle
        }

        // Build API request
        let apiURL: String
        do {
            apiURL = try getAPIURL(deploymentName: requestModel, provider: effectiveProvider)
        } catch {
            onError(error)
            return requestHandle
        }

        guard let url = URL(string: apiURL) else {
            DiagnosticsLogger.log(
                .aiService,
                level: .error,
                message: "❌ Invalid URL",
                metadata: ["url": apiURL]
            )
            onError(AIError.invalidURL)
            return requestHandle
        }

        let needsAuth = effectiveProvider == .openai || effectiveProvider == .githubModels
        let isGitHubModels = effectiveProvider == .githubModels

        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: "📤 Building request",
            metadata: [
                "url": apiURL,
                "hasAPIKey": "\(!modelAPIKey.isEmpty)",
                "needsAuth": "\(needsAuth)",
                "isGitHubModels": "\(isGitHubModels)"
            ]
        )

        // Inject memory context into messages
        let systemPrompt = messages.first { $0.role == .system }?.content
        let conversationHistory = messages.filter { $0.role != .system }
        let memoryContext = MemoryContextProvider.shared.buildContext(
            currentConversationId: conversationId
        )
        let messagesWithMemory = OpenAIRequestBuilder.buildMessagesWithMemory(
            systemPrompt: systemPrompt,
            memoryContext: memoryContext,
            conversationHistory: conversationHistory
        )

        guard
            let request = OpenAIRequestBuilder.createChatCompletionsRequest(
                url: url,
                messages: messagesWithMemory,
                model: requestModel,
                stream: stream,
                tools: tools,
                apiKey: needsAuth ? modelAPIKey : "",
                isAzure: usesAzureEndpoint,
                isGitHubModels: isGitHubModels
            )
        else {
            DiagnosticsLogger.log(
                .aiService,
                level: .error,
                message: "❌ Failed to create request"
            )
            onError(AIError.invalidRequest)
            return requestHandle
        }

        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: "🌐 Starting stream request",
            metadata: [
                "url": url.absoluteString,
                "model": requestModel,
                "stream": "\(stream)"
            ]
        )

        if stream {
            let callbacks = StreamCallbacks(
                onChunk: onChunk,
                onComplete: onComplete,
                onError: onError,
                onToolCall: onToolCall,
                onToolCallRequested: onToolCallRequested,
                onReasoning: onReasoning
            )
            streamResponse(
                request: request,
                callbacks: callbacks,
                isMultiModelRequest: isMultiModelRequest,
                modelName: requestModel,
                initialFlightID: flightID
            )
        } else {
            nonStreamResponse(
                request: request,
                modelName: requestModel,
                isMultiModelRequest: isMultiModelRequest,
                onChunk: onChunk,
                onComplete: onComplete,
                onError: onError,
                onToolCall: onToolCall,
                onReasoning: onReasoning,
                initialFlightID: flightID
            )
        }
        return requestHandle
    }

    // MARK: - Multi-Model Parallel Requests

    // swiftlint:disable function_body_length cyclomatic_complexity
    /// Sends a message to multiple models in parallel using TaskGroup.
    /// Each model streams independently, and tool calls are deferred until the user selects a response.
    ///
    /// - Parameters:
    ///   - messages: The conversation history to send
    ///   - models: Array of model names to query in parallel
    ///   - temperature: Optional temperature override
    ///   - onChunk: Called with (modelName, chunk) for each streaming chunk
    ///   - onModelComplete: Called when a specific model finishes streaming
    ///   - onAllComplete: Called when all models have finished
    ///   - onError: Called with (modelName, error) when a model encounters an error
    ///   - onPendingToolCall: Called when a model requests a tool call (deferred until selection)
    ///   - onReasoning: Called with (modelName, reasoning) for reasoning content
    @discardableResult
    func sendToMultipleModels(
        messages: [Message],
        models: [String],
        temperature: Double? = nil,
        onChunk: @escaping @Sendable (String, String) -> Void,
        onModelComplete: @escaping @Sendable (String) -> Void,
        onAllComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (String, Error) -> Void,
        onPendingToolCall: (@Sendable (String, String, String, [String: Any]) -> Void)? = nil,
        onReasoning: (@Sendable (String, String) -> Void)? = nil
    ) -> AITextBatchRequest {
        let flightID = RequestFlightID()
        let requestHandle = AITextBatchRequest(service: self, flightID: flightID)

        guard !models.isEmpty else {
            onError("", AIError.missingModel)
            onAllComplete()
            return requestHandle
        }

        func rejectBatch(_ error: Error) {
            models.forEach { onError($0, error) }
            onAllComplete()
        }

        let requestModels = models.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let modelRequests = Array(zip(models, requestModels))
        guard !requestModels.contains(where: \.isEmpty) else {
            rejectBatch(AIError.missingModel)
            return requestHandle
        }

        var uniqueModels: Set<String> = []
        if let duplicateModel = requestModels.first(where: { !uniqueModels.insert($0).inserted }) {
            rejectBatch(AIError.apiError("Duplicate model in multi-model request: \(duplicateModel)"))
            return requestHandle
        }

        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: "🔀 Starting multi-model request",
            metadata: ["models": requestModels.joined(separator: ", ")]
        )

        let previousBatchTask = multiModelTask.take()
        let previousDataTasks = multiModelDataTasks.compactMap { _, flight -> URLSessionDataTask? in
            var flight = flight
            return flight.take()
        }
        multiModelDataTasks.removeAll()
        let previousStreamTasks = multiModelStreamTasks.compactMap { _, flight -> Task<Void, Never>? in
            var flight = flight
            return flight.take()
        }
        multiModelStreamTasks.removeAll()
        let previousNonStreamToolTasks = multiModelNonStreamToolTasks.compactMap { _, flight -> Task<Void, Never>? in
            var flight = flight
            return flight.take()
        }
        multiModelNonStreamToolTasks.removeAll()
        let previousSimulatedRequests = multiModelSimulatedTextRequests.compactMap { _, flight -> SimulatedTextRequestHandle? in
            var flight = flight
            return flight.take()
        }
        multiModelSimulatedTextRequests.removeAll()
        let previousAnthropicProviders = multiModelAnthropicProviders.compactMap { _, flight -> (any AIProviderProtocol)? in
            var flight = flight
            return flight.take()
        }
        multiModelAnthropicProviders.removeAll()
        #if !os(watchOS)
            let previousAppleTasks = multiModelAppleIntelligenceTasks.compactMap { _, flight -> AppleIntelligenceRequestHandle? in
                var flight = flight
                return flight.take()
            }
            multiModelAppleIntelligenceTasks.removeAll()
        #endif

        // Cancel the batch first so queued runners are fenced before active request handles release permits.
        previousBatchTask?.cancel()
        previousDataTasks.forEach { $0.cancel() }
        previousStreamTasks.forEach { $0.cancel() }
        previousNonStreamToolTasks.forEach { $0.cancel() }
        previousSimulatedRequests.forEach { $0.cancel() }
        previousAnthropicProviders.forEach { $0.cancelRequest() }
        #if !os(watchOS)
            previousAppleTasks.forEach { $0.cancel() }
        #endif

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            await withTaskGroup(of: Void.self) { group in
                for (callbackModel, model) in modelRequests {
                    guard !Task.isCancelled, self.multiModelTask.owns(flightID) else { return }
                    let effectiveProvider = self.modelProviders[model] ?? self.provider
                    let preparedEndpoint = self.modelEndpoints[model]
                    let preparedEndpointType = self.modelEndpointTypes[model]
                    let requestFlightObserver = self.requestFlightObserver

                    group.addTask { [weak self] in
                        guard let self else { return }
                        guard !Task.isCancelled else {
                            DiagnosticsLogger.log(
                                .aiService,
                                level: .info,
                                message: "🛑 Multi-model task cancelled before starting model",
                                metadata: ["model": model]
                            )
                            return
                        }

                        let preparedCredential: MultiModelPreparedCredential?
                        if effectiveProvider == .githubModels {
                            do {
                                preparedCredential = try await self.prepareGitHubCredential(for: model)
                            } catch {
                                let message = error.localizedDescription
                                await MainActor.run {
                                    guard !Task.isCancelled, self.multiModelTask.owns(flightID) else { return }
                                    onError(callbackModel, AIError.apiError(message))
                                }
                                return
                            }
                        } else {
                            preparedCredential = nil
                        }
                        let preparedAPIKey = preparedCredential?.value

                        guard !Task.isCancelled else { return }
                        let stillOwnsBatch = await MainActor.run {
                            self.multiModelTask.owns(flightID)
                        }
                        guard stillOwnsBatch else { return }

                        let gitHubPermit: MultiModelRequestRunner.GitHubPermit? = if let preparedAPIKey {
                            MultiModelRequestRunner.GitHubPermit.shared(
                                key: GitHubOAuthService.rateLimitKey(forAccessToken: preparedAPIKey),
                                onQueued: {
                                    requestFlightObserver.record(.multiModelPermitQueued, true)
                                }
                            )
                        } else {
                            nil
                        }

                        await MultiModelRequestRunner.run(gitHubPermit: gitHubPermit) { [weak self] completion in
                            guard let self,
                                  !Task.isCancelled,
                                  self.multiModelTask.owns(flightID)
                            else {
                                completion()
                                return
                            }

                            let callbackForwarder = OrderedMainActorForwarder<MultiModelBatchCallback> { [weak self] event in
                                let ownsBatch = self?.multiModelTask.owns(flightID) == true
                                requestFlightObserver.record(.multiModelCallback, ownsBatch)
                                guard ownsBatch else { return }

                                switch event {
                                case let .chunk(chunk):
                                    guard !completion.isFinished else { return }
                                    onChunk(callbackModel, chunk)

                                case .complete:
                                    guard completion() else { return }
                                    DiagnosticsLogger.log(
                                        .aiService,
                                        level: .info,
                                        message: "✅ Model completed in multi-model request",
                                        metadata: ["model": model]
                                    )
                                    onModelComplete(callbackModel)

                                case let .error(error):
                                    guard completion() else { return }
                                    DiagnosticsLogger.log(
                                        .aiService,
                                        level: .error,
                                        message: "❌ Model failed in multi-model request",
                                        metadata: ["model": model, "error": error.localizedDescription]
                                    )
                                    onError(callbackModel, error)

                                case let .toolRequest(toolID, toolName, arguments):
                                    guard !completion.isFinished else { return }
                                    onPendingToolCall?(callbackModel, toolID, toolName, arguments)

                                case let .reasoning(reasoning):
                                    guard !completion.isFinished else { return }
                                    onReasoning?(callbackModel, reasoning)
                                }
                            }

                            let currentProvider = self.modelProviders[model] ?? self.provider
                            let credentialIsCurrent = preparedCredential.map {
                                self.isCurrentGitHubCredential($0, model: model)
                            } ?? true
                            guard currentProvider == effectiveProvider,
                                  self.modelEndpoints[model] == preparedEndpoint,
                                  self.modelEndpointTypes[model] == preparedEndpointType,
                                  credentialIsCurrent
                            else {
                                callbackForwarder.enqueue(
                                    .error(
                                        AIError.apiError(
                                            "Model configuration changed while the request was queued. Please retry."
                                        )
                                    )
                                )
                                return
                            }

                            requestFlightObserver.record(.multiModelStart, true)

                            if effectiveProvider == .githubModels,
                               let preparedAPIKey,
                               let rateLimitError = self.checkGitHubModelsRateLimit(accessToken: preparedAPIKey)
                            {
                                callbackForwarder.enqueue(.error(AIError.apiError(rateLimitError)))
                                return
                            }

                            self.sendMessage(
                                messages: messages,
                                model: model,
                                temperature: temperature,
                                stream: true,
                                tools: nil, // Tools disabled in multi-model mode - deferred
                                conversationId: nil,
                                isMultiModelRequest: true,
                                onChunk: { chunk in
                                    callbackForwarder.enqueue(.chunk(chunk))
                                },
                                onComplete: {
                                    callbackForwarder.enqueue(.complete)
                                },
                                onError: { error in
                                    callbackForwarder.enqueue(.error(error))
                                },
                                onToolCall: nil, // Deferred - not executed during multi-model
                                onToolCallRequested: { toolID, toolName, arguments in
                                    callbackForwarder.enqueue(
                                        .toolRequest(id: toolID, name: toolName, arguments: arguments)
                                    )
                                },
                                onReasoning: { reasoning in
                                    callbackForwarder.enqueue(.reasoning(reasoning))
                                },
                                preparedAPIKey: preparedAPIKey,
                                requestFlightID: flightID
                            )
                        }
                    }
                }
            }

            guard !Task.isCancelled else {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .info,
                    message: "🛑 Multi-model task cancelled, not calling onAllComplete"
                )
                return
            }

            guard self.multiModelTask.clear(ifOwnedBy: flightID) else { return }
            self.multiModelStreamTasks.removeAll()
            DiagnosticsLogger.log(
                .aiService,
                level: .info,
                message: "🏁 All models completed in multi-model request"
            )
            onAllComplete()
        }
        multiModelTask.install(task, id: flightID)?.cancel()
        return requestHandle
    }

    // swiftlint:enable function_body_length cyclomatic_complexity

    private func ownsSimulatedTextRequest(
        _ flightID: RequestFlightID,
        isMultiModelRequest: Bool,
        modelName: String
    ) -> Bool {
        if isMultiModelRequest {
            return multiModelSimulatedTextRequests[modelName]?.owns(flightID) == true
        }
        return currentSimulatedTextRequest.owns(flightID)
    }

    private func beginSimulatedTextRequest(
        flightID: RequestFlightID,
        isMultiModelRequest: Bool,
        modelName: String
    ) -> SimulatedTextRequestHandle {
        let requestHandle = SimulatedTextRequestHandle()
        let previousHandle: SimulatedTextRequestHandle?
        if isMultiModelRequest {
            var flight = multiModelSimulatedTextRequests[modelName] ?? RequestFlight()
            previousHandle = flight.install(requestHandle, id: flightID)
            multiModelSimulatedTextRequests[modelName] = flight
        } else {
            previousHandle = currentSimulatedTextRequest.install(requestHandle, id: flightID)
        }
        previousHandle?.cancel()
        return requestHandle
    }

    @discardableResult
    private func finishSimulatedTextRequest(
        _ flightID: RequestFlightID,
        isMultiModelRequest: Bool,
        modelName: String,
        requestHandle: SimulatedTextRequestHandle
    ) -> Bool {
        let ownedHandle: SimulatedTextRequestHandle?
        if isMultiModelRequest {
            guard var flight = multiModelSimulatedTextRequests[modelName],
                  let handle = flight.take(ifOwnedBy: flightID)
            else {
                return false
            }
            multiModelSimulatedTextRequests.removeValue(forKey: modelName)
            ownedHandle = handle
        } else {
            ownedHandle = currentSimulatedTextRequest.take(ifOwnedBy: flightID)
        }
        guard let ownedHandle, ownedHandle === requestHandle else {
            ownedHandle?.cancel()
            return false
        }
        requestHandle.finish()
        return true
    }

    private func ownedSimulationCallbacks(
        flightID: RequestFlightID,
        isMultiModelRequest: Bool,
        modelName: String,
        requestHandle: SimulatedTextRequestHandle,
        onChunk: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) -> AIServiceResponseSimulationCallbacks {
        AIServiceResponseSimulationCallbacks(
            onChunk: { [weak self] chunk in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let ownsRequest = self.ownsSimulatedTextRequest(
                        flightID,
                        isMultiModelRequest: isMultiModelRequest,
                        modelName: modelName
                    )
                    if isMultiModelRequest {
                        self.requestFlightObserver.record(.multiModelCallback, ownsRequest)
                    }
                    guard ownsRequest else { return }
                    onChunk(chunk)
                }
            },
            onComplete: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let finishedRequest = self.finishSimulatedTextRequest(
                        flightID,
                        isMultiModelRequest: isMultiModelRequest,
                        modelName: modelName,
                        requestHandle: requestHandle
                    )
                    if isMultiModelRequest {
                        self.requestFlightObserver.record(.multiModelCallback, finishedRequest)
                    }
                    guard finishedRequest else { return }
                    onComplete()
                }
            }
        )
    }

    private func simulateUITestResponse(
        messages: [Message],
        stream: Bool,
        flightID: RequestFlightID,
        isMultiModelRequest: Bool,
        modelName: String,
        onChunk: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) {
        let requestHandle = beginSimulatedTextRequest(
            flightID: flightID,
            isMultiModelRequest: isMultiModelRequest,
            modelName: modelName
        )
        let callbacks = ownedSimulationCallbacks(
            flightID: flightID,
            isMultiModelRequest: isMultiModelRequest,
            modelName: modelName,
            requestHandle: requestHandle,
            onChunk: onChunk,
            onComplete: onComplete
        )
        let fallback = "Mock response"
        let userContent = messages.last(where: { $0.role == .user })?.content ?? fallback

        // Handle title generation
        if userContent.starts(with: "Generate a very short title") {
            // Extract the original content from the prompt
            // Prompt format: ... starts with: "CONTENT". Only respond ...
            if let range = userContent.range(of: "starts with: \""),
               let endRange = userContent.range(of: "\". Only respond")
            {
                let content = String(userContent[range.upperBound ..< endRange.lowerBound])
                // Return just the content as the title (or a shortened version)
                let title = String(content.prefix(50))
                callbacks.onChunk(title)
                callbacks.onComplete()
                return
            }
        }

        let response = "UI Test Response: \(userContent)"

        if stream {
            let task = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                callbacks.onChunk(response)
                callbacks.onComplete()
            }
            requestHandle.install(task)
        } else {
            let task = Task { @MainActor in
                callbacks.onChunk(response)
                callbacks.onComplete()
            }
            requestHandle.install(task)
        }
    }

    private func ownsDataFlight(
        _ flightID: RequestFlightID,
        isMultiModelRequest: Bool,
        modelName: String
    ) -> Bool {
        if isMultiModelRequest {
            return multiModelDataTasks[modelName]?.owns(flightID) == true
        }
        return currentTask.owns(flightID)
    }

    @discardableResult
    private func clearDataFlight(
        _ flightID: RequestFlightID,
        isMultiModelRequest: Bool,
        modelName: String
    ) -> Bool {
        if isMultiModelRequest {
            guard var flight = multiModelDataTasks[modelName],
                  flight.clear(ifOwnedBy: flightID)
            else {
                return false
            }
            multiModelDataTasks.removeValue(forKey: modelName)
            return true
        }
        return currentTask.clear(ifOwnedBy: flightID)
    }

    private func takeDataTask(
        isMultiModelRequest: Bool,
        modelName: String
    ) -> URLSessionDataTask? {
        if isMultiModelRequest {
            var flight = multiModelDataTasks.removeValue(forKey: modelName)
            return flight?.take()
        }
        return currentTask.take()
    }

    @discardableResult
    private func installDataTask(
        _ task: URLSessionDataTask,
        flightID: RequestFlightID,
        isMultiModelRequest: Bool,
        modelName: String,
        requiresExistingOwner: Bool
    ) -> Bool {
        if isMultiModelRequest {
            var flight = multiModelDataTasks[modelName] ?? RequestFlight()
            guard !requiresExistingOwner || flight.owns(flightID) else { return false }
            flight.install(task, id: flightID)
            multiModelDataTasks[modelName] = flight
            return true
        }

        guard !requiresExistingOwner || currentTask.owns(flightID) else { return false }
        currentTask.install(task, id: flightID)
        return true
    }

    // The Responses API flow handles multimodal payload assembly in one place for debugging clarity.
    // swiftlint:disable superfluous_disable_command
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func responsesAPIRequest(
        messages: [Message],
        model: String,
        conversationId: UUID? = nil,
        onChunk: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)? = nil,
        onReasoning: (@Sendable (String) -> Void)? = nil,
        isMultiModelRequest: Bool = false,
        attempt: Int = 0,
        initialFlightID: RequestFlightID? = nil,
        existingFlightID: RequestFlightID? = nil
    ) {
        let flightID = existingFlightID ?? initialFlightID ?? RequestFlightID()
        guard existingFlightID == nil || ownsDataFlight(
            flightID,
            isMultiModelRequest: isMultiModelRequest,
            modelName: model
        ) else {
            return
        }

        func reportSetupError(_ error: Error) {
            if existingFlightID == nil || clearDataFlight(
                flightID,
                isMultiModelRequest: isMultiModelRequest,
                modelName: model
            ) {
                onError(error)
            }
        }

        // Check if this model has a provider override
        let effectiveProvider = modelProviders[model] ?? provider
        let endpointInfo = customEndpoint(for: model)
        let usesAzureEndpoint = endpointInfo.map { isAzureEndpoint($0.endpoint) } ?? false

        // Apple Intelligence doesn't support the responses API
        if effectiveProvider == .appleIntelligence {
            reportSetupError(AIError.apiError("Apple Intelligence doesn't support the Responses API endpoint"))
            return
        }

        let requestModel = model
        let modelAPIKey = getAPIKey(for: requestModel)
        let apiURL: String
        do {
            apiURL = try getResponsesAPIURL(deploymentName: model, provider: effectiveProvider)
        } catch {
            reportSetupError(error)
            return
        }

        guard let url = URL(string: apiURL) else {
            reportSetupError(AIError.invalidURL)
            return
        }

        // Get available tools for the Responses API
        let tools = getAllAvailableTools()

        if let tools, !tools.isEmpty {
            DiagnosticsLogger.log(
                .aiService,
                level: .info,
                message: "🔧 Responses API: Sending tools",
                metadata: ["count": "\(tools.count)"]
            )
        }

        // Inject memory context into messages
        let systemPrompt = messages.first { $0.role == .system }?.content
        let conversationHistory = messages.filter { $0.role != .system }
        let memoryContext = MemoryContextProvider.shared.buildContext(
            currentConversationId: conversationId
        )
        let messagesWithMemory = OpenAIRequestBuilder.buildMessagesWithMemory(
            systemPrompt: systemPrompt,
            memoryContext: memoryContext,
            conversationHistory: conversationHistory
        )

        guard
            let request = OpenAIRequestBuilder.createResponsesRequest(
                url: url,
                messages: messagesWithMemory,
                model: model,
                tools: tools,
                apiKey: modelAPIKey,
                isAzure: usesAzureEndpoint
            )
        else {
            reportSetupError(AIError.invalidRequest)
            return
        }

        if existingFlightID == nil {
            let previousTask = takeDataTask(
                isMultiModelRequest: isMultiModelRequest,
                modelName: model
            )
            previousTask?.cancel()
        } else {
            guard ownsDataFlight(
                flightID,
                isMultiModelRequest: isMultiModelRequest,
                modelName: model
            ) else {
                return
            }
        }

        let task = urlSession.dataTask(with: request) { [weak self] data, _, error in
            let selfRef = self
            Task { @MainActor in
                guard let self = selfRef else { return }
                let ownsFlight = self.ownsDataFlight(
                    flightID,
                    isMultiModelRequest: isMultiModelRequest,
                    modelName: model
                )
                self.requestFlightObserver.record(.dataCallback, ownsFlight)
                guard ownsFlight else { return }

                if let error {
                    // Don't report error if it was cancelled
                    if (error as NSError).code == NSURLErrorCancelled {
                        self.clearDataFlight(
                            flightID,
                            isMultiModelRequest: isMultiModelRequest,
                            modelName: model
                        )
                        return
                    }

                    if self.shouldRetry(error: error, attempt: attempt) {
                        DiagnosticsLogger.log(
                            .aiService,
                            level: .info,
                            message: "⚠️ Retrying responses API request (attempt \(attempt + 1))",
                            metadata: ["error": error.localizedDescription]
                        )
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            await self.delay(for: attempt)
                            let ownsFlight = self.ownsDataFlight(
                                flightID,
                                isMultiModelRequest: isMultiModelRequest,
                                modelName: model
                            )
                            self.requestFlightObserver.record(.dataRetry, ownsFlight)
                            guard ownsFlight else { return }
                            self.responsesAPIRequest(
                                messages: messages,
                                model: model,
                                conversationId: conversationId,
                                onChunk: onChunk,
                                onComplete: onComplete,
                                onError: onError,
                                onToolCallRequested: onToolCallRequested,
                                onReasoning: onReasoning,
                                isMultiModelRequest: isMultiModelRequest,
                                attempt: attempt + 1,
                                existingFlightID: flightID
                            )
                        }
                        return
                    }

                    guard self.clearDataFlight(
                        flightID,
                        isMultiModelRequest: isMultiModelRequest,
                        modelName: model
                    ) else {
                        return
                    }
                    onError(error)
                    return
                }

                guard let data else {
                    guard self.clearDataFlight(
                        flightID,
                        isMultiModelRequest: isMultiModelRequest,
                        modelName: model
                    ) else {
                        return
                    }
                    onError(AIError.noData)
                    return
                }

                do {
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                    if let errorDict = json?["error"] as? [String: Any],
                       let message = errorDict["message"] as? String
                    {
                        guard self.clearDataFlight(
                            flightID,
                            isMultiModelRequest: isMultiModelRequest,
                            modelName: model
                        ) else {
                            return
                        }
                        onError(AIError.apiError(message))
                        return
                    }

                    if let outputArray = json?["output"] as? [[String: Any]] {
                        let result = OpenAIRequestBuilder.deliverResponsesOutput(
                            outputArray,
                            onChunk: { chunk in
                                guard self.ownsDataFlight(
                                    flightID,
                                    isMultiModelRequest: isMultiModelRequest,
                                    modelName: model
                                ) else {
                                    return
                                }
                                onChunk(chunk)
                            },
                            onReasoning: { reasoning in
                                guard self.ownsDataFlight(
                                    flightID,
                                    isMultiModelRequest: isMultiModelRequest,
                                    modelName: model
                                ) else {
                                    return
                                }
                                onReasoning?(reasoning)
                            },
                            onToolCallRequested: { toolID, toolName, arguments in
                                guard self.ownsDataFlight(
                                    flightID,
                                    isMultiModelRequest: isMultiModelRequest,
                                    modelName: model
                                ) else {
                                    return
                                }
                                onToolCallRequested?(toolID, toolName, arguments)
                            }
                        )

                        guard self.ownsDataFlight(
                            flightID,
                            isMultiModelRequest: isMultiModelRequest,
                            modelName: model
                        ) else {
                            return
                        }

                        if result.hasToolCalls {
                            DiagnosticsLogger.log(
                                .aiService,
                                level: .info,
                                message: "🔧 Responses API: Tool calls detected",
                                metadata: ["count": "\(result.toolCalls.count)"]
                            )
                        }
                    }

                    guard self.clearDataFlight(
                        flightID,
                        isMultiModelRequest: isMultiModelRequest,
                        modelName: model
                    ) else {
                        return
                    }
                    onComplete()
                } catch {
                    guard self.clearDataFlight(
                        flightID,
                        isMultiModelRequest: isMultiModelRequest,
                        modelName: model
                    ) else {
                        return
                    }
                    onError(error)
                }
            }
        }

        guard installDataTask(
            task,
            flightID: flightID,
            isMultiModelRequest: isMultiModelRequest,
            modelName: model,
            requiresExistingOwner: existingFlightID != nil
        ) else {
            task.cancel()
            return
        }
        task.resume()
    }

    // swiftlint:enable superfluous_disable_command

    // MARK: - Helper Methods for streamResponse

    private nonisolated func getHTTPErrorMessage(statusCode: Int, requestURL: URL?) -> String {
        switch statusCode {
        case 400:
            if requestURL?.absoluteString.lowercased().contains("openai.azure.com") == true {
                return "HTTP \(statusCode) - Invalid Azure deployment or API version (\(azureAPIVersion))."
            }
            return "HTTP \(statusCode) - Invalid request. Check your model name and parameters."
        case 429:
            return "Too many requests. Please wait a minute before trying again."
        case 403:
            if requestURL?.absoluteString.contains("models.github.ai") == true {
                return "Rate limit exceeded. GitHub Models has usage limits. Please wait a few minutes."
            }
            return "HTTP \(statusCode) - Forbidden. Check your API key permissions."
        case 500, 502, 503, 504:
            return "Server error (\(statusCode)). Please try again in a moment."
        default:
            return "HTTP \(statusCode)"
        }
    }

    /// Extracts error message from API response JSON, with special handling for rate limits
    private nonisolated func extractAPIErrorMessage(from data: Data, statusCode: Int) -> String {
        // Check for rate limit status codes first
        if statusCode == 429 {
            // Try to get more specific message, but provide friendly fallback
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                // Make the message more user-friendly
                if message.lowercased().contains("rate") || message.lowercased().contains("limit") {
                    return "Too many requests. Please wait a minute before trying again."
                }
                return message
            }
            return "Too many requests. Please wait a minute before trying again."
        }

        // Try to parse as JSON error response
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // OpenAI-style error: {"error": {"message": "..."}}
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                return message
            }
            // Simple message field: {"message": "..."}
            if let message = json["message"] as? String {
                return message
            }
            // GitHub Models style: {"error": "...", "error_description": "..."}
            if let errorDesc = json["error_description"] as? String {
                return errorDesc
            }
            if let error = json["error"] as? String {
                return error
            }
        }
        // Fall back to raw text if not JSON
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return String(text.prefix(200))
        }
        return "HTTP \(statusCode)"
    }

    /// Check if error body indicates rate limiting (for 403 responses)
    private nonisolated func isRateLimitErrorBody(_ data: Data) -> Bool {
        guard let errorString = String(data: data, encoding: .utf8) else { return false }
        let lowercased = errorString.lowercased()
        return lowercased.contains("rate limit") ||
            lowercased.contains("rate_limit") ||
            lowercased.contains("too many requests") ||
            lowercased.contains("ratelimit")
    }

    private func ownsStreamFlight(
        _ flightID: RequestFlightID,
        isMultiModelRequest: Bool,
        modelName: String?
    ) -> Bool {
        if isMultiModelRequest {
            guard let modelName else { return false }
            return multiModelStreamTasks[modelName]?.owns(flightID) == true
        }
        return currentStreamTask.owns(flightID)
    }

    @discardableResult
    private func clearStreamFlight(
        _ flightID: RequestFlightID,
        isMultiModelRequest: Bool,
        modelName: String?
    ) -> Bool {
        if isMultiModelRequest {
            guard let modelName,
                  var flight = multiModelStreamTasks[modelName],
                  flight.clear(ifOwnedBy: flightID)
            else {
                return false
            }
            multiModelStreamTasks.removeValue(forKey: modelName)
            return true
        }
        return currentStreamTask.clear(ifOwnedBy: flightID)
    }

    private func takeStreamTask(
        isMultiModelRequest: Bool,
        modelName: String?
    ) -> Task<Void, Never>? {
        if isMultiModelRequest {
            guard let modelName else { return nil }
            var flight = multiModelStreamTasks.removeValue(forKey: modelName)
            return flight?.take()
        }
        return currentStreamTask.take()
    }

    @discardableResult
    private func installStreamTask(
        _ task: Task<Void, Never>,
        flightID: RequestFlightID,
        isMultiModelRequest: Bool,
        modelName: String?,
        requiresExistingOwner: Bool
    ) -> Bool {
        if isMultiModelRequest {
            guard let modelName else { return false }
            var flight = multiModelStreamTasks[modelName] ?? RequestFlight()
            guard !requiresExistingOwner || flight.owns(flightID) else { return false }
            flight.install(task, id: flightID)
            multiModelStreamTasks[modelName] = flight
            return true
        }

        guard !requiresExistingOwner || currentStreamTask.owns(flightID) else { return false }
        currentStreamTask.install(task, id: flightID)
        return true
    }

    @discardableResult
    private func deliverStreamBuffers(
        content: String,
        reasoning: String,
        callbacks: StreamCallbacks,
        flightID: RequestFlightID,
        isMultiModelRequest: Bool,
        modelName: String?,
        terminal: Bool
    ) -> Bool {
        guard ownsStreamFlight(
            flightID,
            isMultiModelRequest: isMultiModelRequest,
            modelName: modelName
        ) else {
            return false
        }

        if !content.isEmpty {
            callbacks.onChunk(content)
            guard ownsStreamFlight(
                flightID,
                isMultiModelRequest: isMultiModelRequest,
                modelName: modelName
            ) else {
                return false
            }
        }

        if !reasoning.isEmpty {
            callbacks.onReasoning?(reasoning)
            guard ownsStreamFlight(
                flightID,
                isMultiModelRequest: isMultiModelRequest,
                modelName: modelName
            ) else {
                return false
            }
        }

        if terminal {
            guard clearStreamFlight(
                flightID,
                isMultiModelRequest: isMultiModelRequest,
                modelName: modelName
            ) else {
                return false
            }
            callbacks.onComplete()
        }
        return true
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func streamResponse(
        request: URLRequest,
        callbacks: StreamCallbacks,
        attempt: Int = 0,
        isMultiModelRequest: Bool = false,
        modelName: String? = nil,
        initialFlightID: RequestFlightID? = nil,
        existingFlightID: RequestFlightID? = nil
    ) {
        let session = urlSession
        let flightID = existingFlightID ?? initialFlightID ?? RequestFlightID()

        if existingFlightID != nil {
            guard ownsStreamFlight(
                flightID,
                isMultiModelRequest: isMultiModelRequest,
                modelName: modelName
            ) else {
                return
            }
        } else {
            let previousTask = takeStreamTask(
                isMultiModelRequest: isMultiModelRequest,
                modelName: modelName
            )
            if previousTask != nil, !isMultiModelRequest {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .info,
                    message: "⚠️ Cancelling existing stream task before starting new one"
                )
            }
            previousTask?.cancel()
        }

        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: "🔄 Creating new stream task",
            metadata: ["url": request.url?.absoluteString ?? "unknown"]
        )

        let task = Task { [weak self] in
            guard let self else { return }
            var hasReceivedData = false

            do {
                // Use withTaskCancellationHandler to ensure proper cleanup
                try await withTaskCancellationHandler {
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        DiagnosticsLogger.log(
                            .aiService,
                            level: .error,
                            message: "❌ Invalid response type"
                        )
                        throw AIError.invalidResponse
                    }

                    DiagnosticsLogger.log(
                        .aiService,
                        level: .info,
                        message: "📥 HTTP response received",
                        metadata: [
                            "statusCode": "\(httpResponse.statusCode)",
                            "url": request.url?.absoluteString ?? "unknown"
                        ]
                    )

                    guard httpResponse.statusCode == 200 else {
                        // Read the error response body for better error messages
                        var errorData = Data()
                        do {
                            for try await byte in bytes {
                                errorData.append(byte)
                                // Limit error body size to prevent memory issues
                                if errorData.count > 4096 {
                                    break
                                }
                            }
                        } catch {
                            // Ignore errors reading error body
                        }

                        // Capture rate limit headers for GitHub Models (even on error), scoped per token.
                        let isGitHubModelsRequest = request.url?.host?.contains("models.github.ai") == true
                        let accessToken = request.value(forHTTPHeaderField: "Authorization")
                            .map { $0.replacingOccurrences(of: "Bearer ", with: "") }

                        if isGitHubModelsRequest, let accessToken, !accessToken.isEmpty {
                            await MainActor.run {
                                GitHubOAuthService.shared.updateRateLimit(from: httpResponse, forAccessToken: accessToken)

                                // Check if this is a rate limit error (429 or 403 with rate limit message)
                                let statusCode = httpResponse.statusCode
                                if statusCode == 429 ||
                                    (statusCode == 403 && self.isRateLimitErrorBody(errorData))
                                {
                                    GitHubOAuthService.shared.updateRetryAfter(from: httpResponse, forAccessToken: accessToken)
                                }
                            }
                        }

                        let errorMessage: String = if !errorData.isEmpty {
                            self.extractAPIErrorMessage(from: errorData, statusCode: httpResponse.statusCode)
                        } else {
                            await MainActor.run {
                                self.getHTTPErrorMessage(
                                    statusCode: httpResponse.statusCode,
                                    requestURL: request.url
                                )
                            }
                        }

                        DiagnosticsLogger.log(
                            .aiService,
                            level: .error,
                            message: "❌ API error response",
                            metadata: [
                                "statusCode": "\(httpResponse.statusCode)",
                                "error": errorMessage,
                                "url": request.url?.absoluteString ?? "unknown"
                            ]
                        )
                        throw AIError.apiError(errorMessage)
                    }

                    // Capture rate limit headers on success for GitHub Models (scoped per token).
                    let isGitHubModelsRequest = request.url?.host?.contains("models.github.ai") == true
                    let accessToken = request.value(forHTTPHeaderField: "Authorization")
                        .map { $0.replacingOccurrences(of: "Bearer ", with: "") }
                    if isGitHubModelsRequest, let accessToken, !accessToken.isEmpty {
                        await MainActor.run {
                            GitHubOAuthService.shared.updateRateLimit(from: httpResponse, forAccessToken: accessToken)
                            GitHubOAuthService.shared.clearRetryAfter(forAccessToken: accessToken)
                        }
                    }

                    var buffer = Data()
                    var currentToolCallBuffers: [Int: [String: Any]] = [:]
                    var toolCallIds: [Int: String] = [:]

                    let guardedToolCall: (@Sendable (String, String, [String: Any]) async -> String)? = if let onToolCall = callbacks.onToolCall {
                        { [weak self] toolCallID, toolName, arguments in
                            guard let self else { return "" }
                            let ownsFlight = await MainActor.run {
                                self.ownsStreamFlight(
                                    flightID,
                                    isMultiModelRequest: isMultiModelRequest,
                                    modelName: modelName
                                )
                            }
                            guard ownsFlight, !Task.isCancelled else { return "" }

                            let result = await onToolCall(toolCallID, toolName, arguments)
                            let stillOwnsFlight = await MainActor.run {
                                self.ownsStreamFlight(
                                    flightID,
                                    isMultiModelRequest: isMultiModelRequest,
                                    modelName: modelName
                                )
                            }
                            guard stillOwnsFlight, !Task.isCancelled else { return "" }
                            return result
                        }
                    } else {
                        nil
                    }

                    let guardedToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)? = if let onToolCallRequested = callbacks.onToolCallRequested {
                        { [weak self] toolCallID, toolName, arguments in
                            let arguments = UncheckedSendableWrapper(arguments)
                            MainActor.assumeIsolated {
                                guard let self,
                                      !Task.isCancelled,
                                      self.ownsStreamFlight(
                                          flightID,
                                          isMultiModelRequest: isMultiModelRequest,
                                          modelName: modelName
                                      )
                                else {
                                    return
                                }
                                onToolCallRequested(toolCallID, toolName, arguments.value)
                            }
                        }
                    } else {
                        nil
                    }

                    // Batching buffers
                    var contentBuffer = ""
                    var reasoningBuffer = ""
                    var totalBytesReceived = 0

                    // Maximum line length to prevent OOM from malformed streams without newlines
                    let maxLineLength = 65536 // 64KB

                    for try await byte in bytes {
                        // Check for cancellation at each byte
                        try Task.checkCancellation()

                        hasReceivedData = true
                        totalBytesReceived += 1
                        buffer.append(byte)

                        // Prevent unbounded buffer growth from malformed streams
                        if buffer.count > maxLineLength {
                            throw AynaError.apiError(message: "Malformed stream: line exceeds maximum length")
                        }

                        // Log first byte received
                        if totalBytesReceived == 1 {
                            DiagnosticsLogger.log(
                                .aiService,
                                level: .info,
                                message: "📦 First byte received from stream"
                            )
                        }

                        // Check if we have a newline (UTF-8: 0x0A)
                        if byte == 0x0A {
                            if let line = String(data: buffer, encoding: .utf8) {
                                let ownsFlight = await MainActor.run {
                                    self.ownsStreamFlight(
                                        flightID,
                                        isMultiModelRequest: isMultiModelRequest,
                                        modelName: modelName
                                    )
                                }
                                guard ownsFlight else { throw CancellationError() }

                                let result = await OpenAIStreamParser.processStreamLine(
                                    line,
                                    toolCallBuffers: currentToolCallBuffers,
                                    toolCallIds: toolCallIds,
                                    onToolCall: guardedToolCall,
                                    onToolCallRequested: guardedToolCallRequested
                                )
                                let ownsAfterParser = await MainActor.run {
                                    self.ownsStreamFlight(
                                        flightID,
                                        isMultiModelRequest: isMultiModelRequest,
                                        modelName: modelName
                                    )
                                }
                                guard ownsAfterParser else { throw CancellationError() }
                                try Task.checkCancellation()

                                currentToolCallBuffers = result.toolCallBuffers
                                toolCallIds = result.toolCallIds

                                if let content = result.content {
                                    contentBuffer += content
                                }
                                if let reasoning = result.reasoning {
                                    reasoningBuffer += reasoning
                                }

                                if result.shouldComplete {
                                    // Flush remaining buffers
                                    let contentToSend = contentBuffer
                                    let reasoningToSend = reasoningBuffer
                                    _ = await MainActor.run {
                                        self.deliverStreamBuffers(
                                            content: contentToSend,
                                            reasoning: reasoningToSend,
                                            callbacks: callbacks,
                                            flightID: flightID,
                                            isMultiModelRequest: isMultiModelRequest,
                                            modelName: modelName,
                                            terminal: true
                                        )
                                    }
                                    return
                                }

                                // Deliver each parsed SSE event before waiting for another byte.
                                // Deferring a short tail until a later event can silently lose it
                                // when Stop cancels a quiet stream between events. Platform views
                                // perform their own render throttling where needed.
                                if !contentBuffer.isEmpty || !reasoningBuffer.isEmpty {
                                        let contentToSend = contentBuffer
                                        let reasoningToSend = reasoningBuffer
                                        let delivered = await MainActor.run {
                                            self.deliverStreamBuffers(
                                                content: contentToSend,
                                                reasoning: reasoningToSend,
                                                callbacks: callbacks,
                                                flightID: flightID,
                                                isMultiModelRequest: isMultiModelRequest,
                                                modelName: modelName,
                                                terminal: false
                                            )
                                        }
                                        guard delivered else { return }
                                        contentBuffer = ""
                                        reasoningBuffer = ""
                                }
                            }
                            buffer.removeAll()
                        }
                    }

                    // Some providers close immediately after their final SSE `data:` record
                    // without a trailing newline. Parse that residual record once before EOF
                    // finalization instead of silently discarding it.
                    if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                        let ownsFlight = await MainActor.run {
                            self.ownsStreamFlight(
                                flightID,
                                isMultiModelRequest: isMultiModelRequest,
                                modelName: modelName
                            )
                        }
                        guard ownsFlight else { throw CancellationError() }
                        let result = await OpenAIStreamParser.processStreamLine(
                            line,
                            toolCallBuffers: currentToolCallBuffers,
                            toolCallIds: toolCallIds,
                            onToolCall: guardedToolCall,
                            onToolCallRequested: guardedToolCallRequested
                        )
                        currentToolCallBuffers = result.toolCallBuffers
                        toolCallIds = result.toolCallIds
                        if let content = result.content {
                            contentBuffer += content
                        }
                        if let reasoning = result.reasoning {
                            reasoningBuffer += reasoning
                        }
                        buffer.removeAll()
                    }

                    // Flush any remaining content
                    let contentToSend = contentBuffer
                    let reasoningToSend = reasoningBuffer
                    let receivedData = hasReceivedData
                    let bytesReceived = totalBytesReceived
                    await MainActor.run {
                        guard self.ownsStreamFlight(
                            flightID,
                            isMultiModelRequest: isMultiModelRequest,
                            modelName: modelName
                        ) else {
                            return
                        }

                        DiagnosticsLogger.log(
                            .aiService,
                            level: .info,
                            message: "📊 Stream ended",
                            metadata: [
                                "totalBytesReceived": "\(bytesReceived)",
                                "hasReceivedData": "\(receivedData)",
                                "contentBufferLength": "\(contentToSend.count)",
                                "reasoningBufferLength": "\(reasoningToSend.count)"
                            ]
                        )

                        // Log warning if no data was received but no error occurred
                        if !receivedData {
                            DiagnosticsLogger.log(
                                .aiService,
                                level: .error,
                                message: "⚠️ Stream completed with no data received",
                                metadata: ["url": request.url?.absoluteString ?? "unknown"]
                            )
                        }

                        self.deliverStreamBuffers(
                            content: contentToSend,
                            reasoning: reasoningToSend,
                            callbacks: callbacks,
                            flightID: flightID,
                            isMultiModelRequest: isMultiModelRequest,
                            modelName: modelName,
                            terminal: true
                        )
                    }
                } onCancel: {
                    DiagnosticsLogger.log(
                        .aiService,
                        level: .info,
                        message: "Stream task cancellation handler triggered"
                    )
                }
            } catch {
                await handleStreamError(
                    error: error,
                    attempt: attempt,
                    hasReceivedData: hasReceivedData,
                    request: request,
                    callbacks: callbacks,
                    isMultiModelRequest: isMultiModelRequest,
                    modelName: modelName,
                    flightID: flightID
                )
            }
        }
        guard installStreamTask(
            task,
            flightID: flightID,
            isMultiModelRequest: isMultiModelRequest,
            modelName: modelName,
            requiresExistingOwner: existingFlightID != nil
        ) else {
            task.cancel()
            return
        }
    }

    /// Parse Server-Sent Events data and deliver chunks (used for non-streaming fallback)
    private func parseSSEData(_ data: Data, callbacks: StreamCallbacks) {
        guard let text = String(data: data, encoding: .utf8) else {
            callbacks.onComplete()
            return
        }

        let lines = text.components(separatedBy: "\n")
        var currentToolCallBuffer: [String: Any] = [:]
        var toolCallId = ""

        for line in lines {
            // Skip empty lines and comments
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty || trimmedLine.hasPrefix(":") {
                continue
            }

            // Handle data: prefix
            if trimmedLine.hasPrefix("data:") {
                let jsonString = String(trimmedLine.dropFirst(5)).trimmingCharacters(in: .whitespaces)

                if jsonString == "[DONE]" {
                    callbacks.onComplete()
                    return
                }

                guard let jsonData = jsonString.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let firstChoice = choices.first
                else {
                    continue
                }

                // Handle delta content
                if let delta = firstChoice["delta"] as? [String: Any] {
                    // Handle regular content
                    if let content = delta["content"] as? String, !content.isEmpty {
                        callbacks.onChunk(content)
                    }

                    // Handle reasoning content
                    if let reasoning = delta["reasoning"] as? String, !reasoning.isEmpty {
                        callbacks.onReasoning?(reasoning)
                    } else if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                        callbacks.onReasoning?(reasoning)
                    }

                    // Handle tool calls
                    if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                        for toolCall in toolCalls {
                            if let id = toolCall["id"] as? String {
                                toolCallId = id
                                currentToolCallBuffer = [:]
                            }
                            if let function = toolCall["function"] as? [String: Any] {
                                if let name = function["name"] as? String {
                                    currentToolCallBuffer["name"] = name
                                }
                                if let args = function["arguments"] as? String {
                                    let existing = currentToolCallBuffer["arguments"] as? String ?? ""
                                    currentToolCallBuffer["arguments"] = existing + args
                                }
                            }
                        }
                    }
                }

                // Check for finish_reason
                if let finishReason = firstChoice["finish_reason"] as? String {
                    if finishReason == "tool_calls",
                       let name = currentToolCallBuffer["name"] as? String,
                       let argsString = currentToolCallBuffer["arguments"] as? String
                    {
                        if let argsData = argsString.data(using: .utf8),
                           let arguments = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                        {
                            callbacks.onToolCallRequested?(toolCallId, name, arguments)
                        }
                    }
                }
            }
        }

        callbacks.onComplete()
    }

    private nonisolated func isStreamCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }

    private func handleStreamError(
        error: Error,
        attempt: Int,
        hasReceivedData: Bool,
        request: URLRequest,
        callbacks: StreamCallbacks,
        isMultiModelRequest: Bool = false,
        modelName: String? = nil,
        flightID: RequestFlightID
    ) async {
        if isStreamCancellation(error) {
            DiagnosticsLogger.log(
                .aiService,
                level: .info,
                message: "Stream task cancelled"
            )
            let cleared = clearStreamFlight(
                flightID,
                isMultiModelRequest: isMultiModelRequest,
                modelName: modelName
            )
            requestFlightObserver.record(.streamCancellation, cleared)
            return
        }

        guard ownsStreamFlight(
            flightID,
            isMultiModelRequest: isMultiModelRequest,
            modelName: modelName
        ) else {
            return
        }

        if shouldRetry(error: error, attempt: attempt, hasReceivedData: hasReceivedData) {
            // Get retry-after date for GitHub Models rate limits
            let isGitHubModelsRequest = request.url?.host?.contains("models.github.ai") == true
            let accessToken = request.value(forHTTPHeaderField: "Authorization")
                .map { $0.replacingOccurrences(of: "Bearer ", with: "") }

            let retryAfterDate: Date? = if isGitHubModelsRequest, let accessToken, !accessToken.isEmpty {
                GitHubOAuthService.shared.retryAfterDate(forAccessToken: accessToken)
            } else {
                nil
            }

            DiagnosticsLogger.log(
                .aiService,
                level: .info,
                message: "⚠️ Retrying stream request (attempt \(attempt + 1))",
                metadata: [
                    "error": error.localizedDescription,
                    "retryAfter": retryAfterDate?.description ?? "none"
                ]
            )
            await delay(for: attempt, retryAfterDate: retryAfterDate)
            let ownsFlight = ownsStreamFlight(
                flightID,
                isMultiModelRequest: isMultiModelRequest,
                modelName: modelName
            )
            requestFlightObserver.record(.streamRetry, ownsFlight)
            guard ownsFlight else { return }
            streamResponse(
                request: request,
                callbacks: callbacks,
                attempt: attempt + 1,
                isMultiModelRequest: isMultiModelRequest,
                modelName: modelName,
                existingFlightID: flightID
            )
            return
        }

        guard clearStreamFlight(
            flightID,
            isMultiModelRequest: isMultiModelRequest,
            modelName: modelName
        ) else {
            return
        }

        // Check if it's a timeout error and provide a better message
        if let urlError = error as? URLError, urlError.code == .timedOut {
            callbacks.onError(
                AIError.apiError(
                    "Request timed out. The model may be slow or overloaded. Please try again."
                )
            )
        } else if let urlError = error as? URLError, urlError.code == .networkConnectionLost {
            callbacks.onError(
                AIError.apiError(
                    "Network connection was lost. The server may have rejected the request."
                )
            )
        } else {
            callbacks.onError(error)
        }
    }

    private func ownsNonStreamToolFlight(
        _ flightID: RequestFlightID,
        isMultiModelRequest: Bool,
        modelName: String
    ) -> Bool {
        if isMultiModelRequest {
            return multiModelNonStreamToolTasks[modelName]?.owns(flightID) == true
        }
        return currentNonStreamToolTask.owns(flightID)
    }

    private func ownsNonStreamToolExecution(
        _ flightID: RequestFlightID,
        isMultiModelRequest: Bool,
        modelName: String
    ) -> Bool {
        ownsDataFlight(
            flightID,
            isMultiModelRequest: isMultiModelRequest,
            modelName: modelName
        ) && ownsNonStreamToolFlight(
            flightID,
            isMultiModelRequest: isMultiModelRequest,
            modelName: modelName
        )
    }

    @discardableResult
    private func clearNonStreamToolFlight(
        _ flightID: RequestFlightID,
        isMultiModelRequest: Bool,
        modelName: String
    ) -> Bool {
        if isMultiModelRequest {
            guard var flight = multiModelNonStreamToolTasks[modelName],
                  flight.clear(ifOwnedBy: flightID)
            else {
                return false
            }
            multiModelNonStreamToolTasks.removeValue(forKey: modelName)
            return true
        }
        return currentNonStreamToolTask.clear(ifOwnedBy: flightID)
    }

    @discardableResult
    private func installNonStreamToolTask(
        _ task: Task<Void, Never>,
        flightID: RequestFlightID,
        isMultiModelRequest: Bool,
        modelName: String
    ) -> Bool {
        guard ownsDataFlight(
            flightID,
            isMultiModelRequest: isMultiModelRequest,
            modelName: modelName
        ) else {
            return false
        }

        if isMultiModelRequest {
            var flight = multiModelNonStreamToolTasks[modelName] ?? RequestFlight()
            let previousTask = flight.install(task, id: flightID)
            multiModelNonStreamToolTasks[modelName] = flight
            previousTask?.cancel()
            return true
        }

        currentNonStreamToolTask.install(task, id: flightID)?.cancel()
        return true
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func nonStreamResponse(
        request: URLRequest,
        modelName: String,
        isMultiModelRequest: Bool,
        onChunk: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onToolCall: (@Sendable (String, String, [String: Any]) async -> String)? = nil,
        onReasoning: (@Sendable (String) -> Void)? = nil,
        attempt: Int = 0,
        initialFlightID: RequestFlightID? = nil,
        existingFlightID: RequestFlightID? = nil
    ) {
        let flightID = existingFlightID ?? initialFlightID ?? RequestFlightID()
        if existingFlightID == nil {
            let previousTask = takeDataTask(
                isMultiModelRequest: isMultiModelRequest,
                modelName: modelName
            )
            previousTask?.cancel()
        } else {
            guard ownsDataFlight(
                flightID,
                isMultiModelRequest: isMultiModelRequest,
                modelName: modelName
            ) else {
                return
            }
        }

        let task = urlSession.dataTask(with: request) { [weak self] data, _, error in
            let selfRef = self
            Task { @MainActor in
                guard let self = selfRef else { return }
                let ownsFlight = self.ownsDataFlight(
                    flightID,
                    isMultiModelRequest: isMultiModelRequest,
                    modelName: modelName
                )
                self.requestFlightObserver.record(.dataCallback, ownsFlight)
                guard ownsFlight else { return }

                if let error {
                    if self.shouldRetry(error: error, attempt: attempt) {
                        DiagnosticsLogger.log(
                            .aiService,
                            level: .info,
                            message: "⚠️ Retrying non-stream request (attempt \(attempt + 1))",
                            metadata: ["error": error.localizedDescription]
                        )
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            await self.delay(for: attempt)
                            let ownsFlight = self.ownsDataFlight(
                                flightID,
                                isMultiModelRequest: isMultiModelRequest,
                                modelName: modelName
                            )
                            self.requestFlightObserver.record(.dataRetry, ownsFlight)
                            guard ownsFlight else { return }
                            self.nonStreamResponse(
                                request: request,
                                modelName: modelName,
                                isMultiModelRequest: isMultiModelRequest,
                                onChunk: onChunk,
                                onComplete: onComplete,
                                onError: onError,
                                onToolCall: onToolCall,
                                onReasoning: onReasoning,
                                attempt: attempt + 1,
                                existingFlightID: flightID
                            )
                        }
                        return
                    }
                    guard self.clearDataFlight(
                        flightID,
                        isMultiModelRequest: isMultiModelRequest,
                        modelName: modelName
                    ) else {
                        return
                    }
                    onError(error)
                    return
                }

                guard let data else {
                    guard self.clearDataFlight(
                        flightID,
                        isMultiModelRequest: isMultiModelRequest,
                        modelName: modelName
                    ) else {
                        return
                    }
                    onError(AIError.invalidResponse)
                    return
                }

                do {
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                    if let errorDict = json?["error"] as? [String: Any],
                       let message = errorDict["message"] as? String
                    {
                        guard self.clearDataFlight(
                            flightID,
                            isMultiModelRequest: isMultiModelRequest,
                            modelName: modelName
                        ) else {
                            return
                        }
                        onError(AIError.apiError(message))
                        return
                    }

                    if let choices = json?["choices"] as? [[String: Any]],
                       let firstChoice = choices.first,
                       let message = firstChoice["message"] as? [String: Any]
                    {
                        // Check for reasoning in various possible locations
                        var foundReasoning: String?
                        if let reasoning = message["reasoning"] as? String {
                            foundReasoning = reasoning
                        } else if let reasoning = message["reasoning_content"] as? String {
                            foundReasoning = reasoning
                        } else if let usage = json?["usage"] as? [String: Any],
                                  let details = usage["completion_tokens_details"] as? [String: Any],
                                  let reasoningTokens = details["reasoning_tokens"] as? Int, reasoningTokens > 0
                        {
                            // Show reasoning token count
                            foundReasoning = "💭 Reasoning tokens used: \(reasoningTokens)"
                        }

                        // Handle reasoning content if found
                        if let reasoning = foundReasoning, let onReasoning {
                            onReasoning(reasoning)
                            guard self.ownsDataFlight(
                                flightID,
                                isMultiModelRequest: isMultiModelRequest,
                                modelName: modelName
                            ) else {
                                return
                            }
                        }

                        // Handle regular content
                        if let contentField = message["content"], !(contentField is NSNull) {
                            let textSegments = OpenAIStreamParser.extractTextSegments(
                                from: contentField,
                                source: "nonstream.chat",
                                metadata: ["phase": "final"]
                            )

                            for segment in textSegments where !segment.isEmpty {
                                guard self.ownsDataFlight(
                                    flightID,
                                    isMultiModelRequest: isMultiModelRequest,
                                    modelName: modelName
                                ) else {
                                    return
                                }
                                onChunk(segment)
                            }
                        }

                        if let toolCalls = message["tool_calls"] as? [[String: Any]],
                           let onToolCall
                        {
                            let toolTask = Task { @MainActor [weak self] in
                                guard let self else { return }

                                for toolCall in toolCalls {
                                    if let id = toolCall["id"] as? String,
                                       let function = toolCall["function"] as? [String: Any],
                                       let name = function["name"] as? String,
                                       let argsString = function["arguments"] as? String,
                                       let argsData = argsString.data(using: .utf8),
                                       let arguments = try? JSONSerialization.jsonObject(with: argsData)
                                       as? [String: Any]
                                    {
                                        guard !Task.isCancelled,
                                              self.ownsNonStreamToolExecution(
                                                  flightID,
                                                  isMultiModelRequest: isMultiModelRequest,
                                                  modelName: modelName
                                              )
                                        else {
                                            return
                                        }

                                        let result = await onToolCall(id, name, arguments)

                                        guard !Task.isCancelled,
                                              self.ownsNonStreamToolExecution(
                                                  flightID,
                                                  isMultiModelRequest: isMultiModelRequest,
                                                  modelName: modelName
                                              )
                                        else {
                                            return
                                        }

                                            onChunk("\n\n[Tool: \(name)]\n\(result)\n")

                                        guard self.ownsNonStreamToolExecution(
                                            flightID,
                                            isMultiModelRequest: isMultiModelRequest,
                                            modelName: modelName
                                        ) else {
                                            return
                                        }
                                    }
                                }

                                guard !Task.isCancelled,
                                      self.ownsNonStreamToolExecution(
                                          flightID,
                                          isMultiModelRequest: isMultiModelRequest,
                                          modelName: modelName
                                      ),
                                      self.clearNonStreamToolFlight(
                                          flightID,
                                          isMultiModelRequest: isMultiModelRequest,
                                          modelName: modelName
                                      ),
                                      self.clearDataFlight(
                                          flightID,
                                          isMultiModelRequest: isMultiModelRequest,
                                          modelName: modelName
                                      )
                                else {
                                    return
                                }

                                    onComplete()
                                }

                            guard self.installNonStreamToolTask(
                                toolTask,
                                flightID: flightID,
                                isMultiModelRequest: isMultiModelRequest,
                                modelName: modelName
                            ) else {
                                toolTask.cancel()
                                return
                            }
                            return
                        }

                        guard self.clearDataFlight(
                            flightID,
                            isMultiModelRequest: isMultiModelRequest,
                            modelName: modelName
                        ) else {
                            return
                        }
                        onComplete()
                    } else {
                        guard self.clearDataFlight(
                            flightID,
                            isMultiModelRequest: isMultiModelRequest,
                            modelName: modelName
                        ) else {
                            return
                        }
                        onError(AIError.invalidResponse)
                    }
                } catch {
                    guard self.clearDataFlight(
                        flightID,
                        isMultiModelRequest: isMultiModelRequest,
                        modelName: modelName
                    ) else {
                        return
                    }
                    onError(error)
                }
            }
        }

        guard installDataTask(
            task,
            flightID: flightID,
            isMultiModelRequest: isMultiModelRequest,
            modelName: modelName,
            requiresExistingOwner: existingFlightID != nil
        ) else {
            task.cancel()
            return
        }
        task.resume()
    }

    #if !os(watchOS)
        private func ownsAppleIntelligenceFlight(
            _ flightID: RequestFlightID,
            isMultiModelRequest: Bool,
            modelName: String
        ) -> Bool {
            if isMultiModelRequest {
                return multiModelAppleIntelligenceTasks[modelName]?.owns(flightID) == true
            }
            return currentAppleIntelligenceTask.owns(flightID)
        }

        @discardableResult
        private func clearAppleIntelligenceFlight(
            _ flightID: RequestFlightID,
            isMultiModelRequest: Bool,
            modelName: String
        ) -> Bool {
            if isMultiModelRequest {
                guard var flight = multiModelAppleIntelligenceTasks[modelName],
                      flight.clear(ifOwnedBy: flightID)
                else {
                    return false
                }
                multiModelAppleIntelligenceTasks.removeValue(forKey: modelName)
                return true
            }
            return currentAppleIntelligenceTask.clear(ifOwnedBy: flightID)
        }

        @discardableResult
        private func finishAppleIntelligenceFlight(
            _ flightID: RequestFlightID,
            request: AppleIntelligenceRequestContext,
            sessionID: String
        ) -> Bool {
            guard clearAppleIntelligenceFlight(
                flightID,
                isMultiModelRequest: request.isMultiModelRequest,
                modelName: request.modelName
            ) else {
                return false
            }
            request.service.clearSession(conversationId: sessionID)
            return true
        }

        private func installAppleIntelligenceHandle(
            _ handle: AppleIntelligenceRequestHandle,
            flightID: RequestFlightID,
            isMultiModelRequest: Bool,
            modelName: String
        ) -> AppleIntelligenceRequestHandle? {
            if isMultiModelRequest {
                var flight = multiModelAppleIntelligenceTasks[modelName] ?? RequestFlight()
                let previous = flight.install(handle, id: flightID)
                multiModelAppleIntelligenceTasks[modelName] = flight
                return previous
            }
            return currentAppleIntelligenceTask.install(handle, id: flightID)
        }

        private func appleSessionID(for request: AppleIntelligenceRequestContext) -> String {
            let conversationScope = request.conversationID?.uuidString ?? "default"
            let requestScope = UUID().uuidString
            return request.isMultiModelRequest
                ? "multi:\(conversationScope):\(request.modelName):\(requestScope)"
                : "\(conversationScope):\(requestScope)"
        }

        private func appleSystemInstructions(
            messages: [Message],
            conversationID: UUID?
        ) -> String {
            var instructions = messages.first(where: { $0.role == .system })?.content
                ?? "You are a helpful assistant."
            let memoryContext = MemoryContextProvider.shared.buildContext(
                currentConversationId: conversationID
            )
            guard memoryContext.hasContent else { return instructions }

            let memoryParts = [
                memoryContext.sessionMetadata,
                memoryContext.userMemory,
                memoryContext.conversationSummaries,
            ].compactMap(\.self)
            if !memoryParts.isEmpty {
                instructions += "\n\n" + memoryParts.joined(separator: "\n\n")
            }
            return instructions
        }

        private func appleToolMatchPlan(messages: [Message]) -> AppleToolMatchPlan {
            struct PendingCall {
                let messageID: UUID
                let index: Int
                let normalizedID: String
            }

            var plan = AppleToolMatchPlan()
            var pendingByOriginalID: [String: [PendingCall]] = [:]
            var occurrenceByOriginalID: [String: Int] = [:]
            let originalIDs = Set(messages.flatMap { ($0.toolCalls ?? []).map(\.id) })
            var assignedIDs: Set<String> = []
            for message in messages {
                switch message.role {
                case .assistant:
                    for (index, call) in (message.toolCalls ?? []).enumerated() {
                        let occurrence = occurrenceByOriginalID[call.id, default: 0]
                        occurrenceByOriginalID[call.id] = occurrence + 1
                        var normalizedID = call.id
                        if occurrence > 0 || assignedIDs.contains(normalizedID) {
                            var suffix = max(1, occurrence)
                            repeat {
                                normalizedID = "\(call.id)#\(suffix)"
                                suffix += 1
                            } while originalIDs.contains(normalizedID) || assignedIDs.contains(normalizedID)
                        }
                        assignedIDs.insert(normalizedID)
                        pendingByOriginalID[call.id, default: []].append(PendingCall(
                            messageID: message.id,
                            index: index,
                            normalizedID: normalizedID
                        ))
                    }
                case .tool:
                    for (index, call) in (message.toolCalls ?? []).enumerated() {
                        guard var pending = pendingByOriginalID[call.id],
                              let matched = pending.popLast()
                        else {
                            continue
                        }
                        pendingByOriginalID[call.id] = pending
                        plan.assistantCallIDs[matched.messageID, default: [:]][matched.index] = matched.normalizedID
                        plan.toolOutputIDs[message.id, default: [:]][index] = matched.normalizedID
                    }
                case .system, .user:
                    break
                }
            }
            return plan
        }

        private func appleHistoryEntries(
            from message: Message,
            matchPlan: AppleToolMatchPlan
        ) -> [AppleIntelligenceHistoryEntry] {
            let content = message.content
            let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)

            switch message.role {
            case .user:
                guard !trimmedContent.isEmpty else { return [] }
                return [AppleIntelligenceHistoryEntry(role: .user, content: content)]
            case .assistant:
                let toolCalls = (message.toolCalls ?? []).enumerated().compactMap { index, toolCall -> AppleIntelligenceToolCall? in
                    guard let normalizedID = matchPlan.assistantCallIDs[message.id]?[index],
                          let data = try? JSONEncoder().encode(toolCall.arguments),
                          let argumentsJSON = String(data: data, encoding: .utf8)
                    else {
                        return nil
                    }
                    return AppleIntelligenceToolCall(
                        id: normalizedID,
                        name: toolCall.toolName,
                        argumentsJSON: argumentsJSON
                    )
                }
                guard !trimmedContent.isEmpty || !toolCalls.isEmpty else { return [] }
                return [AppleIntelligenceHistoryEntry(
                    role: .assistant,
                    content: content,
                    toolCalls: toolCalls
                )]
            case .tool:
                return (message.toolCalls ?? []).enumerated().compactMap { index, toolCall in
                    guard let normalizedID = matchPlan.toolOutputIDs[message.id]?[index] else { return nil }
                    return AppleIntelligenceHistoryEntry(
                        role: .tool,
                        content: trimmedContent.isEmpty ? "(empty tool output)" : content,
                        toolName: toolCall.toolName,
                        toolCallID: normalizedID
                    )
                }
            case .system:
                return []
            }
        }

        private func appleConversationContext(
            messages: [Message]
        ) -> AppleConversationContext? {
            let messages = messages.filter { $0.isSelectedResponse != false }
            guard let promptIndex = messages.lastIndex(where: { $0.role == .user }) else { return nil }
            let matchPlan = appleToolMatchPlan(messages: messages)

            let tailEntries = messages[messages.index(after: promptIndex)...].flatMap {
                appleHistoryEntries(from: $0, matchPlan: matchPlan)
            }
            if !tailEntries.isEmpty {
                let history = messages.flatMap {
                    appleHistoryEntries(from: $0, matchPlan: matchPlan)
                }
                return AppleConversationContext(
                    history: history,
                    prompt: "Continue the conversation using the completed context above.",
                    requiresHistory: true
                )
            }

            let history = messages[..<promptIndex].flatMap {
                appleHistoryEntries(from: $0, matchPlan: matchPlan)
            }
            return AppleConversationContext(
                history: history,
                prompt: messages[promptIndex].content,
                requiresHistory: false
            )
        }

        private func appleHistoryGroups(
            _ history: [AppleIntelligenceHistoryEntry]
        ) -> [[AppleIntelligenceHistoryEntry]] {
            var groups: [[AppleIntelligenceHistoryEntry]] = []
            for entry in history {
                switch entry.role {
                case .user:
                    groups.append([entry])
                case .assistant:
                    if groups.last?.first?.role == .user {
                        groups[groups.count - 1].append(entry)
                    } else {
                        groups.append([entry])
                    }
                case .tool:
                    if let toolCallID = entry.toolCallID,
                       groups.last?.contains(where: {
                           $0.role == .assistant && $0.toolCalls.contains(where: { $0.id == toolCallID })
                       }) == true
                    {
                        groups[groups.count - 1].append(entry)
                    } else {
                        groups.append([entry])
                    }
                }
            }
            return groups
        }

        private func estimatedAppleHistoryTokens(
            _ entries: [AppleIntelligenceHistoryEntry]
        ) -> Int {
            AppleIntelligenceTranscriptBuilder.entries(from: entries).reduce(0) { total, entry in
                total + 12 + estimatedAppleTokens(entry.content)
            }
        }

        private func estimatedAppleTokens(_ text: String) -> Int {
            let scalarCount = text.unicodeScalars.count
            let asciiCount = text.unicodeScalars.lazy.filter(\.isASCII).count
            let nonASCII = scalarCount - asciiCount
            return ((asciiCount + 1) / 2) + nonASCII
        }

        private func compactAppleHistory(
            _ history: [AppleIntelligenceHistoryEntry],
            contextSize: Int,
            systemInstructions: String,
            prompt: String,
            requireNewestGroup: Bool
        ) -> [AppleIntelligenceHistoryEntry]? {
            let responseReserve = max(64, min(1024, contextSize / 4))
            let fixedCost = responseReserve + estimatedAppleTokens(systemInstructions) +
                estimatedAppleTokens(prompt) + 32
            guard fixedCost <= contextSize else { return nil }
            var remaining = contextSize - fixedCost
            var retainedGroups: [[AppleIntelligenceHistoryEntry]] = []
            for group in appleHistoryGroups(history).reversed() {
                let groupCost = estimatedAppleHistoryTokens(group)
                guard groupCost <= remaining else {
                    return requireNewestGroup && retainedGroups.isEmpty ? nil : retainedGroups.flatMap(\.self)
                }
                retainedGroups.insert(group, at: 0)
                remaining -= groupCost
            }
            return retainedGroups.flatMap(\.self)
        }

        private func fallbackAppleServiceRequest(
            request: AppleIntelligenceRequestContext,
            conversationContext: AppleConversationContext,
            sessionID: String,
            systemInstructions: String,
            temperature: Double
        ) -> AppleIntelligenceRequest? {
            guard let history = compactAppleHistory(
                conversationContext.history,
                contextSize: request.service.contextSize,
                systemInstructions: systemInstructions,
                prompt: conversationContext.prompt,
                requireNewestGroup: conversationContext.requiresHistory
            ) else {
                return nil
            }
            return AppleIntelligenceRequest(
                conversationID: sessionID,
                prompt: conversationContext.prompt,
                history: history,
                systemInstructions: systemInstructions,
                temperature: temperature
            )
        }

        private func validatedAppleServiceRequest(
            request: AppleIntelligenceRequestContext,
            conversationContext: AppleConversationContext,
            sessionID: String,
            systemInstructions: String,
            temperature: Double
        ) async -> AppleIntelligenceRequest? {
            var candidate = AppleIntelligenceRequest(
                conversationID: sessionID,
                prompt: conversationContext.prompt,
                history: conversationContext.history,
                systemInstructions: systemInstructions,
                temperature: temperature
            )
            let maxInputTokens = max(0, request.service.contextSize - max(64, min(1024, request.service.contextSize / 4)))
            if let initialCount = await request.service.tokenCount(for: candidate) {
                guard initialCount > maxInputTokens else { return candidate }

                var groups = appleHistoryGroups(candidate.history)
                while !groups.isEmpty {
                    if conversationContext.requiresHistory, groups.count == 1 {
                        return nil
                    }
                    groups.removeFirst()
                    candidate = AppleIntelligenceRequest(
                        conversationID: sessionID,
                        prompt: conversationContext.prompt,
                        history: groups.flatMap(\.self),
                        systemInstructions: systemInstructions,
                        temperature: temperature
                    )
                    guard let tokenCount = await request.service.tokenCount(for: candidate) else {
                        return fallbackAppleServiceRequest(
                            request: request,
                            conversationContext: conversationContext,
                            sessionID: sessionID,
                            systemInstructions: systemInstructions,
                            temperature: temperature
                        )
                    }
                    if tokenCount <= maxInputTokens {
                        return candidate
                    }
                }
                return nil
            }

            return fallbackAppleServiceRequest(
                request: request,
                conversationContext: conversationContext,
                sessionID: sessionID,
                systemInstructions: systemInstructions,
                temperature: temperature
            )
        }

        private func ownedAppleServiceRequest(
            request: AppleIntelligenceRequestContext,
            conversationContext: AppleConversationContext,
            sessionID: String,
            systemInstructions: String,
            temperature: Double,
            flightID: RequestFlightID
        ) async -> AppleIntelligenceRequest? {
            guard let serviceRequest = await validatedAppleServiceRequest(
                request: request,
                conversationContext: conversationContext,
                sessionID: sessionID,
                systemInstructions: systemInstructions,
                temperature: temperature
            ) else {
                guard finishAppleIntelligenceFlight(
                    flightID,
                    request: request,
                    sessionID: sessionID
                ) else {
                    return nil
                }
                request.onError(AIError.apiError("Apple Intelligence context is too large to continue safely"))
                return nil
            }
            guard ownsAppleIntelligenceFlight(
                flightID,
                isMultiModelRequest: request.isMultiModelRequest,
                modelName: request.modelName
            ) else {
                return nil
            }
            return serviceRequest
        }

        private func handleAppleIntelligenceRequest(
            _ request: AppleIntelligenceRequestContext,
            flightID: RequestFlightID = RequestFlightID()
        ) {
            guard request.service.isAvailable else {
                request.onError(AIError.apiError(request.service.availabilityDescription()))
                return
            }
            guard let conversationContext = appleConversationContext(messages: request.messages) else {
                request.onError(AIError.apiError("No user message found"))
                return
            }

            let systemInstructions = appleSystemInstructions(
                messages: request.messages,
                conversationID: request.conversationID
            )
            let sessionID = appleSessionID(for: request)
            let requestTemperature = request.temperature ?? 0.7
            let task = Task { @MainActor [weak self] in
                guard let self,
                      self.ownsAppleIntelligenceFlight(
                          flightID,
                          isMultiModelRequest: request.isMultiModelRequest,
                          modelName: request.modelName
                      )
                else {
                    return
                }
                guard let serviceRequest = await self.ownedAppleServiceRequest(
                    request: request,
                    conversationContext: conversationContext,
                    sessionID: sessionID,
                    systemInstructions: systemInstructions,
                    temperature: requestTemperature,
                    flightID: flightID
                ) else {
                    return
                }

                if request.stream {
                    await request.service.streamResponse(
                        request: serviceRequest,
                        onChunk: { [weak self] chunk in
                            guard let self,
                                  self.ownsAppleIntelligenceFlight(
                                      flightID,
                                      isMultiModelRequest: request.isMultiModelRequest,
                                      modelName: request.modelName
                                  )
                            else {
                                return
                            }
                            request.onChunk(chunk)
                        },
                        onComplete: { [weak self] in
                            guard let self,
                                  self.finishAppleIntelligenceFlight(
                                      flightID,
                                      request: request,
                                      sessionID: sessionID
                                  )
                            else {
                                return
                            }
                            request.onComplete()
                        },
                        onError: { [weak self] error in
                            guard let self,
                                  self.finishAppleIntelligenceFlight(
                                      flightID,
                                      request: request,
                                      sessionID: sessionID
                                  )
                            else {
                                return
                            }
                            request.onError(error)
                        }
                    )
                } else {
                    await request.service.generateResponse(
                        request: serviceRequest,
                        onComplete: { [weak self] response in
                            guard let self,
                                  self.ownsAppleIntelligenceFlight(
                                      flightID,
                                      isMultiModelRequest: request.isMultiModelRequest,
                                      modelName: request.modelName
                                  )
                            else {
                                return
                            }
                            request.onChunk(response)
                            guard self.finishAppleIntelligenceFlight(
                                flightID,
                                request: request,
                                sessionID: sessionID
                            ) else {
                                return
                            }
                            request.onComplete()
                        },
                        onError: { [weak self] error in
                            guard let self,
                                  self.finishAppleIntelligenceFlight(
                                      flightID,
                                      request: request,
                                      sessionID: sessionID
                                  )
                            else {
                                return
                            }
                            request.onError(error)
                        }
                    )
                }

                guard !Task.isCancelled,
                      self.finishAppleIntelligenceFlight(
                          flightID,
                          request: request,
                          sessionID: sessionID
                      )
                else {
                    return
                }
                request.onError(AIError.apiError("Apple Intelligence request ended without a terminal callback"))
            }
            let handle = AppleIntelligenceRequestHandle(
                task: task,
                service: request.service,
                sessionID: sessionID
            )
            installAppleIntelligenceHandle(
                handle,
                flightID: flightID,
                isMultiModelRequest: request.isMultiModelRequest,
                modelName: request.modelName
            )?.cancel()
        }
    #endif

    // MARK: - Anthropic Provider Handler

    private func ownsAnthropicFlight(
        _ flightID: RequestFlightID,
        isMultiModelRequest: Bool,
        model: String
    ) -> Bool {
        if isMultiModelRequest {
            return multiModelAnthropicProviders[model]?.owns(flightID) == true
        }
        return currentAnthropicProvider.owns(flightID)
    }

    @discardableResult
    private func clearAnthropicFlight(
        _ flightID: RequestFlightID,
        isMultiModelRequest: Bool,
        model: String
    ) -> Bool {
        if isMultiModelRequest {
            guard var flight = multiModelAnthropicProviders[model],
                  flight.clear(ifOwnedBy: flightID)
            else {
                return false
            }
            multiModelAnthropicProviders.removeValue(forKey: model)
            return true
        }
        return currentAnthropicProvider.clear(ifOwnedBy: flightID)
    }

    private func handleAnthropicRequest(
        messages: [Message],
        model: String,
        stream: Bool,
        tools: [[String: Any]]?,
        conversationId: UUID?,
        isMultiModelRequest: Bool,
        callbacks: AIProviderStreamCallbacks,
        flightID: RequestFlightID = RequestFlightID()
    ) {
        let modelAPIKey = getAPIKey(for: model)
        let endpointInfo = customEndpoint(for: model)

        // Validate API key
        guard !modelAPIKey.isEmpty else {
            callbacks.onError(AynaError.missingAPIKey(provider: AIProvider.anthropic.displayName))
            return
        }

        // Build provider config
        let config = AIProviderRequestConfig(
            model: model,
            apiKey: modelAPIKey,
            customEndpoint: endpointInfo?.endpoint,
            maxTokens: nil, // Use provider default
            temperature: nil, // Use provider default
            thinkingBudget: nil // TODO: Add UI for thinking budget
        )

        // Inject memory context into messages
        let systemPrompt = messages.first { $0.role == .system }?.content
        let conversationHistory = messages.filter { $0.role != .system }
        let memoryContext = MemoryContextProvider.shared.buildContext(
            currentConversationId: conversationId
        )
        let messagesWithMemory = OpenAIRequestBuilder.buildMessagesWithMemory(
            systemPrompt: systemPrompt,
            memoryContext: memoryContext,
            conversationHistory: conversationHistory
        )

        // Install ownership before sending because a provider may fail synchronously.
        let provider = anthropicProviderFactory(urlSession)
        if isMultiModelRequest {
            var previousFlight = multiModelAnthropicProviders.removeValue(forKey: model)
            let previousProvider = previousFlight?.take()
            previousProvider?.cancelRequest()
            var flight = RequestFlight<any AIProviderProtocol>()
            flight.install(provider, id: flightID)
            multiModelAnthropicProviders[model] = flight
        } else {
            let previousProvider = currentAnthropicProvider.take()
            previousProvider?.cancelRequest()
            currentAnthropicProvider.install(provider, id: flightID)
        }

        let forwarder = OrderedMainActorForwarder<AnthropicFlightCallback> { [weak self] event in
            guard let self else { return }

            switch event {
            case let .chunk(chunk):
                guard self.ownsAnthropicFlight(
                    flightID,
                    isMultiModelRequest: isMultiModelRequest,
                    model: model
                ) else {
                    return
                }
                callbacks.onChunk(chunk)

            case .complete:
                let ownsFlight = self.ownsAnthropicFlight(
                    flightID,
                    isMultiModelRequest: isMultiModelRequest,
                    model: model
                )
                self.requestFlightObserver.record(.anthropicTerminal, ownsFlight)
                guard ownsFlight,
                      self.clearAnthropicFlight(
                          flightID,
                          isMultiModelRequest: isMultiModelRequest,
                          model: model
                      )
                else {
                    return
                }
                callbacks.onComplete()

            case let .error(error):
                let ownsFlight = self.ownsAnthropicFlight(
                    flightID,
                    isMultiModelRequest: isMultiModelRequest,
                    model: model
                )
                self.requestFlightObserver.record(.anthropicTerminal, ownsFlight)
                guard ownsFlight,
                      self.clearAnthropicFlight(
                          flightID,
                          isMultiModelRequest: isMultiModelRequest,
                          model: model
                      )
                else {
                    return
                }
                callbacks.onError(error)

            case let .toolRequest(toolID, toolName, arguments):
                guard self.ownsAnthropicFlight(
                    flightID,
                    isMultiModelRequest: isMultiModelRequest,
                    model: model
                ) else {
                    return
                }
                callbacks.onToolCallRequested?(toolID, toolName, arguments)

            case let .reasoning(reasoning):
                guard self.ownsAnthropicFlight(
                    flightID,
                    isMultiModelRequest: isMultiModelRequest,
                    model: model
                ) else {
                    return
                }
                callbacks.onReasoning?(reasoning)
            }
        }

        let wrappedCallbacks = AIProviderStreamCallbacks(
            onChunk: { forwarder.enqueue(.chunk($0)) },
            onComplete: { forwarder.enqueue(.complete) },
            onError: { forwarder.enqueue(.error($0)) },
            onToolCallRequested: { toolID, toolName, arguments in
                forwarder.enqueue(.toolRequest(id: toolID, name: toolName, arguments: arguments))
            },
            onReasoning: { forwarder.enqueue(.reasoning($0)) }
        )

        provider.sendMessage(
            messages: messagesWithMemory,
            config: config,
            stream: stream,
            tools: tools,
            callbacks: wrappedCallbacks
        )
    }

    /// Retry logic delegated to AIRetryPolicy
    private func shouldRetry(error: Error, attempt: Int, hasReceivedData: Bool = false) -> Bool {
        AIRetryPolicy.shouldRetry(
            error: error,
            attempt: attempt,
            hasReceivedData: hasReceivedData
        )
    }

    private func delay(for attempt: Int, retryAfterDate: Date? = nil) async {
        await retryDelay(attempt, retryAfterDate)
    }

    enum AIError: LocalizedError {
        case missingAPIKey
        case missingModel
        case invalidResponse
        case invalidRequest
        case apiError(String)
        case invalidURL
        case unsupportedProvider
        case noData
        case contentFiltered(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                "Please add your API key in Settings"
            case .missingModel:
                "Please add or select a model in Settings"
            case .invalidResponse:
                "Invalid response from API"
            case .invalidRequest:
                "Failed to build API request"
            case let .apiError(message):
                message
            case .invalidURL:
                "Invalid API endpoint URL"
            case .unsupportedProvider:
                "Image generation is only supported for OpenAI-compatible providers"
            case .noData:
                "No data received from API"
            case let .contentFiltered(message):
                "Content filtered: \(message)"
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .missingAPIKey:
                "Go to Settings → API Keys to add your key"
            case .missingModel:
                "Go to Settings → Models to select a model"
            case .invalidResponse, .noData:
                "Try again or check your internet connection"
            case .invalidRequest:
                "Try sending a shorter message"
            case .apiError:
                "Check your API configuration or try again later"
            case .invalidURL:
                "Verify the API endpoint URL in Settings"
            case .unsupportedProvider:
                "Switch to an OpenAI-compatible model for image generation"
            case .contentFiltered:
                "Try rephrasing your message"
            }
        }
    }
}

extension AIService {
    private func providerRequiresAPIKey(_ provider: AIProvider) -> Bool {
        switch provider {
        case .appleIntelligence:
            false
        case .openai, .githubModels, .anthropic:
            true
        }
    }

    private func requiresAPIKey(for provider: AIProvider, model: String?) -> Bool {
        guard providerRequiresAPIKey(provider) else { return false }

        guard provider == .openai else { return true }
        guard let endpoint = customEndpoint(for: model)?.endpoint else { return true }

        return OpenAIEndpointResolver.customEndpointRequiresAPIKey(endpoint)
    }

    var requiresAPIKey: Bool {
        let trimmedModel = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = trimmedModel.isEmpty ? nil : trimmedModel
        let activeProvider = normalizedModel.flatMap { modelProviders[$0] } ?? provider
        return requiresAPIKey(for: activeProvider, model: normalizedModel)
    }

    var latestAzureAPIVersion: String {
        azureAPIVersion
    }

    private func isAPIKeyConfigured(for provider: AIProvider, model: String?) -> Bool {
        guard requiresAPIKey(for: provider, model: model) else { return true }

        // For GitHub Models, check OAuth token first
        if provider == .githubModels {
            if GitHubOAuthService.shared.isAuthenticated,
               let token = GitHubOAuthService.shared.getAccessToken(),
               !token.isEmpty
            {
                return true
            }
        }

        // Check for per-model key
        if let model,
           let modelKey = modelAPIKeys[model]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !modelKey.isEmpty
        {
            return true
        }

        // Check if any model has an API key configured
        return modelAPIKeys.values.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var isAPIKeyConfigured: Bool {
        let trimmedModel = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = trimmedModel.isEmpty ? nil : trimmedModel
        let activeProvider = normalizedModel.flatMap { modelProviders[$0] } ?? provider
        return isAPIKeyConfigured(for: activeProvider, model: normalizedModel)
    }

    /// Check if a specific model is ready to use (has API key or doesn't need one)
    func isModelConfigured(_ model: String) -> Bool {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return isAPIKeyConfigured }

        let modelProvider = modelProviders[trimmedModel] ?? provider
        return isAPIKeyConfigured(for: modelProvider, model: trimmedModel)
    }

    var configurationIssues: [String] {
        var issues: [String] = []
        let trimmedModel = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = trimmedModel.isEmpty ? nil : trimmedModel
        let activeProvider = normalizedModel.flatMap { modelProviders[$0] } ?? provider

        if customModels.isEmpty {
            issues.append("Add at least one model in Settings > Model tab")
        } else if normalizedModel == nil {
            issues.append("Select a default model in Settings > Model tab")
        }

        if requiresAPIKey(for: activeProvider, model: normalizedModel),
           !isAPIKeyConfigured(for: activeProvider, model: normalizedModel)
        {
            issues.append("Add an API key for \(activeProvider.displayName)")
        }
        return issues
    }

    var usableModels: [String] {
        var models = customModels.filter { model in
            #if os(watchOS)
                // Apple Intelligence requires on-device processing which isn't available on watchOS
                // The watch app makes API calls directly, not via iPhone relay
                if modelProviders[model] == .appleIntelligence {
                    return false
                }
            #endif
            return true
        }

        // Check if running in UI test mode
        let isUITestMode = ProcessInfo.processInfo.environment["AYNA_UI_TESTING"] == "1" ||
            ProcessInfo.processInfo.arguments.contains("--ui-testing") ||
            ProcessInfo.processInfo.arguments.contains("-AYNA_UI_TESTING")

        // Ensure test model is available during UI testing
        // This is a fallback in case the init-time detection didn't work
        let testModelName = "ui-test-model"
        if isUITestMode, !models.contains(testModelName) {
            models.insert(testModelName, at: 0)
            // Also ensure the test model is fully configured
            if modelProviders[testModelName] == nil {
                modelProviders[testModelName] = .openai
            }
            if modelEndpointTypes[testModelName] == nil {
                modelEndpointTypes[testModelName] = .chatCompletions
            }
            if modelAPIKeys[testModelName]?.isEmpty ?? true {
                modelAPIKeys[testModelName] = "ui-test-api-key"
            }
            if !customModels.contains(testModelName) {
                customModels.insert(testModelName, at: 0)
            }
            if selectedModel.isEmpty {
                selectedModel = testModelName
            }
        }

        return models
    }

    /// Models that support text generation (excludes image generation models)
    /// Use this for multi-model comparison mode where comparing text to images doesn't make sense
    var textGenerationModels: [String] {
        usableModels.filter { model in
            getModelCapability(model) != .imageGeneration
        }
    }

    private func setupiCloudSync() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(ubiquitousKeyValueStoreDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default
        )
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    @objc private func ubiquitousKeyValueStoreDidChange(notification _: NSNotification) {
        let store = NSUbiquitousKeyValueStore.default

        Task { @MainActor in
            if let models = store.array(forKey: "customModels") as? [String] {
                self.customModels = models
            }

            if let providers = store.dictionary(forKey: "modelProviders") as? [String: String] {
                self.modelProviders = providers.compactMapValues { AIProvider(rawValue: $0) }
            }

            if let endpointTypes = store.dictionary(forKey: "modelEndpointTypes") as? [String: String] {
                self.modelEndpointTypes = endpointTypes.compactMapValues {
                    APIEndpointType(rawValue: $0)
                }
            }

            if let endpoints = store.dictionary(forKey: "modelEndpoints") as? [String: String] {
                self.modelEndpoints = endpoints
            }
        }
    }
}

// MARK: - Tool Management

extension AIService {
    /// Returns system prompt context for agentic capabilities.
    /// This should be appended to the user's system prompt when tools are available.
    func getAgenticSystemPromptContext() -> String? {
        var contexts: [String] = []

        // Add web_fetch context on all platforms
        if let webFetchContext = WebFetchService.shared.systemPromptContext() {
            contexts.append(webFetchContext)
        }

        // Add macOS-specific tool context
        #if os(macOS)
            if let builtinContext = builtinToolService?.systemPromptContext() {
                contexts.append(builtinContext)
            }
        #endif

        return contexts.isEmpty ? nil : contexts.joined(separator: "\n\n")
    }

    /// Returns all available tools for function calling, including built-in tools and MCP tools.
    /// This is a cross-platform method that returns Tavily on all platforms and MCP only on macOS.
    func getAllAvailableTools() -> [[String: Any]]? {
        var tools: [[String: Any]] = []

        // Add web search tool (Tavily if configured, else DuckDuckGo)
        #if os(watchOS)
            // On watchOS, use synced settings
            if webSearchEnabled {
                tools.append(WebSearchCoordinator.shared.toolDefinition())
                DiagnosticsLogger.log(
                    .aiService,
                    level: .info,
                    message: "🔧 Added web_search tool (watchOS)"
                )
            }
        #else
            if WebSearchCoordinator.shared.isAvailable {
                tools.append(WebSearchCoordinator.shared.toolDefinition())
                DiagnosticsLogger.log(
                    .aiService,
                    level: .info,
                    message: "🔧 Added web_search tool (\(WebSearchCoordinator.shared.activeProvider))"
                )
            }
        #endif

        // Add web_fetch tool (available on all platforms)
        if WebFetchService.shared.isEnabled {
            tools.append(WebFetchService.shared.toolDefinition())
            DiagnosticsLogger.log(
                .aiService,
                level: .info,
                message: "🔧 Added web_fetch tool"
            )
        }

        // Add native agentic tools (macOS only, excludes web_fetch which is cross-platform)
        #if os(macOS)
            if let builtinService = builtinToolService {
                // Get all tool definitions except web_fetch (already added above)
                let builtinTools = builtinService.allToolDefinitions().filter { tool in
                    guard let function = tool["function"] as? [String: Any],
                          let name = function["name"] as? String
                    else { return true }
                    return name != WebFetchService.toolName
                }
                tools.append(contentsOf: builtinTools)
                DiagnosticsLogger.log(
                    .aiService,
                    level: .info,
                    message: "🔧 Added builtin tools",
                    metadata: [
                        "count": "\(builtinTools.count)",
                        "isEnabled": "\(builtinService.isEnabled)"
                    ]
                )
            } else {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .info,
                    message: "⚠️ builtinToolService is nil"
                )
            }
        #endif

        // Add MCP tools (macOS only)
        #if os(macOS)
            let mcpTools = MCPServerManager.shared.getEnabledToolsAsOpenAIFunctions()
            tools.append(contentsOf: mcpTools)
            if !mcpTools.isEmpty {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .info,
                    message: "🔧 Added MCP tools",
                    metadata: ["count": "\(mcpTools.count)"]
                )
            }
        #endif

        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: "🔧 getAllAvailableTools returning",
            metadata: ["totalTools": "\(tools.count)", "isNil": "\(tools.isEmpty)"]
        )

        return tools.isEmpty ? nil : tools
    }

    /// Checks if a tool call is for a built-in tool (like web_search) that we handle internally.
    /// - Parameter toolName: The name of the tool being called
    /// - Returns: True if this is a built-in tool we handle, false if it should be routed to MCP
    func isBuiltInTool(_ toolName: String) -> Bool {
        #if os(watchOS)
            return toolName == WebSearchCoordinator.toolName || WebFetchService.isWebFetchTool(toolName)
        #elseif os(macOS)
            return toolName == WebSearchCoordinator.toolName || BuiltinToolService.isBuiltinTool(toolName) || WebFetchService.isWebFetchTool(toolName)
        #else
            return toolName == WebSearchCoordinator.toolName || WebFetchService.isWebFetchTool(toolName)
        #endif
    }

    /// Executes a built-in tool call and returns the result.
    /// - Parameters:
    ///   - toolName: The name of the tool to execute
    ///   - arguments: The arguments passed to the tool
    ///   - conversationId: The conversation ID for permission tracking (macOS only)
    /// - Returns: The tool execution result as a string
    func executeBuiltInTool(name toolName: String, arguments: [String: Any], conversationId: UUID? = nil) async -> String {
        // Handle web_fetch on all platforms
        if WebFetchService.isWebFetchTool(toolName) {
            return await WebFetchService.shared.executeToolCall(arguments: arguments)
        }

        #if os(watchOS)
            switch toolName {
            case WebSearchCoordinator.toolName:
                return await WebSearchCoordinator.shared.executeToolCall(arguments: arguments)
            default:
                return "Error: Unknown built-in tool '\(toolName)'"
            }
        #elseif os(macOS)
            // Check for native agentic tools first (excluding web_fetch which is handled above)
            if BuiltinToolService.isBuiltinTool(toolName) {
                guard let service = builtinToolService else {
                    return "Error: Agentic tools not configured"
                }
                guard let convId = conversationId else {
                    return "Error: Conversation ID required for agentic tools"
                }
                return await service.executeToolCall(
                    toolName: toolName,
                    arguments: arguments,
                    conversationId: convId
                )
            }

            switch toolName {
            case WebSearchCoordinator.toolName:
                return await WebSearchCoordinator.shared.executeToolCall(arguments: arguments)
            default:
                return "Error: Unknown built-in tool '\(toolName)'"
            }
        #else
            switch toolName {
            case WebSearchCoordinator.toolName:
                return await WebSearchCoordinator.shared.executeToolCall(arguments: arguments)
            default:
                return "Error: Unknown built-in tool '\(toolName)'"
            }
        #endif
    }

    /// Executes a built-in tool call and returns both the result and citations (if any).
    /// - Parameters:
    ///   - toolName: The name of the tool to execute
    ///   - arguments: The arguments passed to the tool
    ///   - conversationId: The conversation ID for permission tracking (macOS only)
    /// - Returns: Tuple of (result string, optional citations for inline display)
    func executeBuiltInToolWithCitations(
        name toolName: String,
        arguments: [String: Any],
        conversationId: UUID? = nil
    ) async -> (String, [CitationReference]?) {
        // Handle web_fetch on all platforms (no citations)
        if WebFetchService.isWebFetchTool(toolName) {
            let result = await WebFetchService.shared.executeToolCall(arguments: arguments)
            return (result, nil)
        }

        #if os(watchOS)
            // watchOS uses WebSearchCoordinator (with citations)
            switch toolName {
            case WebSearchCoordinator.toolName:
                let (result, citations) = await WebSearchCoordinator.shared.executeToolCallWithCitations(arguments: arguments)
                return (result, citations.isEmpty ? nil : citations)
            default:
                let result = await executeBuiltInTool(name: toolName, arguments: arguments)
                return (result, nil)
            }
        #elseif os(macOS)
            // Native agentic tools don't have citations (excluding web_fetch which is handled above)
            if BuiltinToolService.isBuiltinTool(toolName) {
                let result = await executeBuiltInTool(name: toolName, arguments: arguments, conversationId: conversationId)
                return (result, nil)
            }

            switch toolName {
            case WebSearchCoordinator.toolName:
                let (result, citations) = await WebSearchCoordinator.shared.executeToolCallWithCitations(arguments: arguments)
                return (result, citations.isEmpty ? nil : citations)
            default:
                return ("Error: Unknown built-in tool '\(toolName)'", nil)
            }
        #else
            switch toolName {
            case WebSearchCoordinator.toolName:
                let (result, citations) = await WebSearchCoordinator.shared.executeToolCallWithCitations(arguments: arguments)
                return (result, citations.isEmpty ? nil : citations)
            default:
                return ("Error: Unknown built-in tool '\(toolName)'", nil)
            }
        #endif
    }

    #if os(watchOS)
    #endif
}

// Keychain Helper

// swiftlint:enable type_body_length

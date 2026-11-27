import Combine
import Foundation
import os

enum AIProvider: String, CaseIterable, Codable {
    case openai = "OpenAI"
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

enum AITextRequestLane: Sendable {
    case foreground
    case background
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
    case multiModelStart
    case multiModelCallback
}

struct RequestFlightObserver: Sendable {
    let record: @Sendable (RequestFlightCheckpoint, Bool) -> Void

    static let none = RequestFlightObserver { _, _ in }
}

@MainActor
final class AITextRequest {
    weak var service: AIService?
    let flightID: RequestFlightID

    init(service: AIService, flightID: RequestFlightID) {
        self.service = service
        self.flightID = flightID
    }

    func cancel() {
        service?.cancelTextRequest(flightID)
    }
}

@MainActor
final class AITextBatchRequest {
    weak var service: AIService?
    let flightID: RequestFlightID

    init(service: AIService, flightID: RequestFlightID) {
        self.service = service
        self.flightID = flightID
    }

    func cancel() {
        service?.cancelTextBatchRequest(flightID)
    }
}

final class SimulatedTextRequestHandle: @unchecked Sendable {
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
    @MainActor
    final class AIImageRequest {
        weak var service: AIService?
        let flightID: RequestFlightID

        init(service: AIService, flightID: RequestFlightID) {
            self.service = service
            self.flightID = flightID
        }

        func cancel() {
            service?.cancelImageRequest(flightID)
        }
    }
#endif

final class OrderedMainActorForwarder<Event: Sendable>: Sendable {
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

enum AnthropicFlightCallback: @unchecked Sendable {
    case chunk(String)
    case complete
    case error(Error)
    case toolRequest(id: String, name: String, arguments: [String: Any])
    case reasoning(String)
}

enum MultiModelBatchCallback: @unchecked Sendable {
    case chunk(String)
    case complete
    case error(Error)
    case toolRequest(id: String, name: String, arguments: [String: Any])
    case reasoning(String)
}

#if !os(watchOS)
    @MainActor
    struct AppleIntelligenceRequestHandle {
        let task: Task<Void, Never>
        let service: any AppleIntelligenceServing
        let sessionID: String

        func cancel() {
            task.cancel()
            service.clearSession(conversationId: sessionID)
        }
    }

    @MainActor
    struct AppleIntelligenceRequestContext {
        let service: any AppleIntelligenceServing
        let messages: [Message]
        let modelName: String
        let temperature: Double?
        let stream: Bool
        let conversationID: UUID?
        let requestLane: AITextRequestLane
        let isMultiModelRequest: Bool
        let onChunk: @Sendable (String) -> Void
        let onComplete: @Sendable () -> Void
        let onError: @Sendable (Error) -> Void
    }

    struct AppleConversationContext {
        let history: [AppleIntelligenceHistoryEntry]
        let prompt: String
        let requiresHistory: Bool
    }

    struct AppleToolMatchPlan {
        var assistantCallIDs: [UUID: [Int: String]] = [:]
        var toolOutputIDs: [UUID: [Int: String]] = [:]
    }
#endif

struct AIServiceResponseSimulationCallbacks: Sendable {
    let onChunk: @MainActor @Sendable (String) -> Void
    let onComplete: @MainActor @Sendable () -> Void
}

typealias AIServiceResponseSimulator = @MainActor @Sendable (
    [Message],
    AIServiceResponseSimulationCallbacks
) -> Void

@MainActor
class AIService: ObservableObject {
    #if os(macOS)
        static let shared = AIService(
            agentSettingsStore: AgentSettingsStore.shared,
            webFetchService: WebFetchService.shared
        )
    #else
        static let shared = AIService()
    #endif
    static var keychain: KeychainStoring = KeychainStorage.standard

    enum KeychainKeys {
        static let modelAPIKeys = "model_api_keys"
    }

    var keychainLoadSucceeded = false

    @Published var selectedModel: String {
        didSet {
            #if !os(watchOS)
                AppPreferences.storage.set(selectedModel, forKey: "selectedModel")
            #endif
        }
    }

    var currentTask = RequestFlight<URLSessionDataTask>()
    var multiModelDataTasks: [String: RequestFlight<URLSessionDataTask>] = [:]
    var backgroundDataTasks: [RequestFlightID: URLSessionDataTask] = [:]
    var currentRequestBuildTask = RequestFlight<Task<Void, Never>>()
    var multiModelRequestBuildTasks: [String: RequestFlight<Task<Void, Never>>] = [:]
    var backgroundRequestBuildTasks: [RequestFlightID: Task<Void, Never>] = [:]
    var currentStreamTask = RequestFlight<Task<Void, Never>>()
    var backgroundStreamTasks: [RequestFlightID: Task<Void, Never>] = [:]
    var currentSimulatedTextRequest = RequestFlight<SimulatedTextRequestHandle>()
    var multiModelSimulatedTextRequests: [String: RequestFlight<SimulatedTextRequestHandle>] = [:]
    var backgroundSimulatedTextRequests: [RequestFlightID: SimulatedTextRequestHandle] = [:]
    var multiModelTask = RequestFlight<Task<Void, Never>>()
    var multiModelStreamTasks: [String: RequestFlight<Task<Void, Never>>] = [:]
    #if !os(watchOS)
        var currentAppleIntelligenceTask = RequestFlight<AppleIntelligenceRequestHandle>()
        var multiModelAppleIntelligenceTasks: [String: RequestFlight<AppleIntelligenceRequestHandle>] = [:]
        var backgroundAppleIntelligenceTasks: [RequestFlightID: AppleIntelligenceRequestHandle] = [:]
        var imageRequests: [RequestFlightID: OpenAIImageService.RequestHandle] = [:]
    #endif

    var currentAnthropicProvider = RequestFlight<any AIProviderProtocol>()
    var multiModelAnthropicProviders: [String: RequestFlight<any AIProviderProtocol>] = [:]
    var backgroundAnthropicProviders: [RequestFlightID: any AIProviderProtocol] = [:]

    @Published var provider: AIProvider {
        didSet {
            unrecognizedDefaultProviderValue = nil
            modelsInheritingUnrecognizedDefaultProvider.removeAll()
            #if !os(watchOS)
                AppPreferences.storage.set(provider.rawValue, forKey: "aiProvider")
            #endif
        }
    }

    let openAIURL = "https://api.openai.com/v1/chat/completions"
    let azureAPIVersion = "2025-04-01-preview"

    let urlSession: URLSession
    let anthropicProviderFactory: @MainActor (URLSession) -> any AIProviderProtocol
    let retryDelay: @Sendable (Int, Date?) async -> Void
    let requestFlightObserver: RequestFlightObserver
    let responseSimulator: AIServiceResponseSimulator?
    var unrecognizedProviderValues: [String: String] = [:]
    var unrecognizedDefaultProviderValue: String?
    var modelsInheritingUnrecognizedDefaultProvider: Set<String> = []
    #if !os(watchOS)
        let injectedAppleIntelligenceService: (any AppleIntelligenceServing)?
        let imageService: OpenAIImageService
    #endif

    let webFetchService: WebFetchService

    #if os(macOS)
        private(set) var builtinToolService: BuiltinToolService?
        private(set) var permissionService: PermissionService?
    #endif

    @Published var customModels: [String] {
        didSet {
            let retainedModels = Set(customModels)
            unrecognizedProviderValues = unrecognizedProviderValues.filter {
                retainedModels.contains($0.key)
            }
            modelsInheritingUnrecognizedDefaultProvider.formIntersection(retainedModels)
            #if !os(watchOS)
                AppPreferences.storage.set(customModels, forKey: "customModels")
                persistModelProviders()
            #endif
        }
    }

    @Published var modelProviders: [String: AIProvider] {
        didSet {
            for model in modelProviders.keys {
                unrecognizedProviderValues.removeValue(forKey: model)
                modelsInheritingUnrecognizedDefaultProvider.remove(model)
            }
            #if !os(watchOS)
                persistModelProviders()
            #endif
        }
    }

    @Published var modelEndpointTypes: [String: APIEndpointType] {
        didSet {
            #if !os(watchOS)
                let encodedDict = modelEndpointTypes.mapValues { $0.rawValue }
                AppPreferences.storage.set(encodedDict, forKey: "modelEndpointTypes")
            #endif
        }
    }

    @Published var modelEndpoints: [String: String] {
        didSet {
            #if !os(watchOS)
                AppPreferences.storage.set(modelEndpoints, forKey: "modelEndpoints")
            #endif
        }
    }

    @Published var modelThinkingBudgets: [String: Int] {
        didSet {
            #if !os(watchOS)
                AppPreferences.storage.set(modelThinkingBudgets, forKey: "modelThinkingBudgets")
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

    #if os(watchOS)
        @Published var tavilyAPIKey: String = ""
        @Published var tavilyEnabled: Bool = false
        @Published var webSearchEnabled: Bool = false
    #endif

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

    #if os(macOS)
        convenience init(
            urlSession: URLSession? = nil,
            anthropicProviderFactory: @escaping @MainActor (URLSession) -> any AIProviderProtocol = {
                AnthropicProvider(urlSession: $0)
            },
            retryDelay: @escaping @Sendable (Int, Date?) async -> Void = { attempt, retryAfterDate in
                await AIRetryPolicy.wait(for: attempt, retryAfterDate: retryAfterDate)
            },
            requestFlightObserver: RequestFlightObserver = .none,
            responseSimulator: AIServiceResponseSimulator? = nil,
            appleIntelligenceService: (any AppleIntelligenceServing)? = nil,
            agentSettingsStore: AgentSettingsStore,
            webFetchService: WebFetchService? = nil
        ) {
            let resolvedWebFetchService = webFetchService ?? WebFetchService()
            self.init(
                urlSession: urlSession,
                anthropicProviderFactory: anthropicProviderFactory,
                retryDelay: retryDelay,
                requestFlightObserver: requestFlightObserver,
                responseSimulator: responseSimulator,
                appleIntelligenceService: appleIntelligenceService,
                webFetchService: resolvedWebFetchService
            )
            if let builtinService = builtinToolService,
               let permService = permissionService
            {
                agentSettingsStore.attach(
                    builtinToolService: builtinService,
                    permissionService: permService,
                    webFetchService: resolvedWebFetchService
                )
            }
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
        appleIntelligenceService: (any AppleIntelligenceServing)? = nil,
        webFetchService: WebFetchService? = nil
    ) {
        self.anthropicProviderFactory = anthropicProviderFactory
        self.retryDelay = retryDelay
        self.requestFlightObserver = requestFlightObserver
        self.responseSimulator = responseSimulator
        #if os(macOS)
            self.webFetchService = webFetchService ?? WebFetchService()
        #else
            self.webFetchService = webFetchService ?? WebFetchService.shared
        #endif
        #if !os(watchOS)
            injectedAppleIntelligenceService = appleIntelligenceService
        #endif

        let resolvedSession = Self.makeURLSession(providedSession: urlSession)
        self.urlSession = resolvedSession
        #if !os(watchOS)
            imageService = Self.makeImageService(urlSession: resolvedSession, retryDelay: retryDelay)
        #endif

        let initialState = Self.loadInitialConfiguration(isUITesting: RuntimeEnvironment.isUITesting)
        unrecognizedProviderValues = initialState.unrecognizedProviderValues
        unrecognizedDefaultProviderValue = initialState.unrecognizedDefaultProviderValue
        modelsInheritingUnrecognizedDefaultProvider = initialState.modelsInheritingUnrecognizedDefaultProvider
        customModels = initialState.customModels
        modelProviders = initialState.modelProviders
        modelEndpointTypes = initialState.modelEndpointTypes
        modelEndpoints = initialState.modelEndpoints
        modelThinkingBudgets = initialState.modelThinkingBudgets
        modelAPIKeys = initialState.modelAPIKeys
        keychainLoadSucceeded = initialState.keychainLoadSucceeded
        selectedModel = initialState.selectedModel
        provider = initialState.provider
        imageSize = initialState.imageSize
        imageQuality = initialState.imageQuality
        outputFormat = initialState.outputFormat
        outputCompression = initialState.outputCompression

        #if os(macOS)
            let permService = PermissionService()
            let builtinService = BuiltinToolService(permissionService: permService)
            permissionService = permService
            builtinToolService = builtinService
            AgentSettingsStore.apply(
                AgentSettings.load(),
                builtinToolService: builtinService,
                permissionService: permService,
                webFetchService: self.webFetchService
            )
        #endif
    }

    private static func makeURLSession(providedSession: URLSession?) -> URLSession {
        if let providedSession {
            return providedSession
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 1800
        return URLSession(configuration: config)
    }

    func shouldRetry(error: Error, attempt: Int, hasReceivedData: Bool = false) -> Bool {
        AIRetryPolicy.shouldRetry(
            error: error,
            attempt: attempt,
            hasReceivedData: hasReceivedData
        )
    }

    func delay(for attempt: Int, retryAfterDate: Date? = nil) async {
        await retryDelay(attempt, retryAfterDate)
    }

    @discardableResult
    func sendMessage(
        messages: [Message],
        model: String? = nil,
        temperature: Double? = nil,
        stream: Bool = true,
        tools: [[String: Any]]? = nil,
        conversationId: UUID? = nil,
        requestLane: AITextRequestLane = .foreground,
        isMultiModelRequest: Bool = false,
        onChunk: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)? = nil,
        onReasoning: (@Sendable (String) -> Void)? = nil,
        requestFlightID: RequestFlightID? = nil
    ) -> AITextRequest {
        performSendMessage(
            messages: messages,
            model: model,
            temperature: temperature,
            stream: stream,
            tools: tools,
            conversationId: conversationId,
            requestLane: requestLane,
            isMultiModelRequest: isMultiModelRequest,
            onChunk: onChunk,
            onComplete: onComplete,
            onError: onError,
            onToolCallRequested: onToolCallRequested,
            onReasoning: onReasoning,
            requestFlightID: requestFlightID
        )
    }

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
        performSendToMultipleModels(
            messages: messages,
            models: models,
            temperature: temperature,
            onChunk: onChunk,
            onModelComplete: onModelComplete,
            onAllComplete: onAllComplete,
            onError: onError,
            onPendingToolCall: onPendingToolCall,
            onReasoning: onReasoning
        )
    }
}

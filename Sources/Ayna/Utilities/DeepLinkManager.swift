import Combine
import Foundation
import OSLog
import SwiftUI

enum DeepLinkError: LocalizedError {
    case invalidURL
    case missingRequiredParameter(String)
    case invalidProvider(String)
    case invalidEndpointType(String)
    case modelAlreadyExists(String)
    case modelNotFound(String)
    case confirmationInProgress
    case unknownAction(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid deep link URL"
        case let .missingRequiredParameter(param):
            "Missing required parameter: \(param)"
        case let .invalidProvider(provider):
            "Invalid provider: \(provider)"
        case let .invalidEndpointType(type):
            "Invalid endpoint type: \(type)"
        case let .modelAlreadyExists(name):
            "Model '\(name)' already exists"
        case let .modelNotFound(name):
            "Model '\(name)' not found"
        case .confirmationInProgress:
            "Another model confirmation is already in progress"
        case let .unknownAction(action):
            "Unknown action: \(action)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .invalidURL:
            "Check the URL format and try again"
        case let .missingRequiredParameter(param):
            "Add the '\(param)' parameter to the URL"
        case .invalidProvider:
            "Valid providers: OpenAI, Anthropic, Apple Intelligence"
        case .invalidEndpointType:
            "Valid types: Chat Completions, Responses, Image Generation"
        case .modelAlreadyExists:
            "Use a different model name or remove the existing model first"
        case .modelNotFound:
            "Check that the model name is correct"
        case .confirmationInProgress:
            "Finish or cancel the current model confirmation, then try again"
        case .unknownAction:
            "Supported actions: add-model, chat"
        }
    }
}

struct AddModelRequest: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let provider: AIProvider
    let endpoint: String?
    let apiKey: String?
    let endpointType: APIEndpointType

    var displayProvider: String {
        provider.displayName
    }

    var displayEndpointType: String {
        endpointType.displayName
    }
}

struct ChatRequest: Equatable {
    let model: String?
    let prompt: String?
    let systemPrompt: String?
    let modelConfig: AddModelRequest?
}

enum DeepLinkAction: Equatable {
    case addModel(AddModelRequest)
    case chat(ChatRequest)
}

@MainActor
final class DeepLinkManager: ObservableObject {
    static let shared = DeepLinkManager()

    private struct PendingConfirmation {
        let request: AddModelRequest
        let deferredChat: ChatRequest?
    }

    @Published private(set) var pendingAddModel: AddModelRequest?

    var pendingChat: ChatRequest? {
        pendingConfirmation?.deferredChat ?? readyChatQueue.first
    }

    @Published private(set) var errorMessage: String?

    @Published private(set) var errorRecoverySuggestion: String?

    var showAddModelConfirmation: Bool {
        pendingAddModel != nil
    }

    private let aiService: AIService
    private var pendingConfirmation: PendingConfirmation?
    private var readyChatQueue: [ChatRequest] = []

    init(aiService: AIService? = nil) {
        self.aiService = aiService ?? .shared
    }

    func handle(url: URL) async {
        let safeURL = "\(url.scheme ?? "")://\(url.host ?? "")\(url.path)"
        DiagnosticsLogger.log(
            .app,
            level: .info,
            message: "🔗 Handling deep link",
            metadata: ["url": safeURL]
        )

        errorMessage = nil
        errorRecoverySuggestion = nil

        do {
            let action = try parseURL(url)

            switch action {
            case let .addModel(request):
                try installConfirmation(request, deferredChat: nil)
                DiagnosticsLogger.log(
                    .app,
                    level: .info,
                    message: "🔗 Pending add-model confirmation",
                    metadata: ["modelName": request.name]
                )

            case let .chat(request):
                if let modelConfig = request.modelConfig {
                    let modelExists = aiService.customModels.contains(modelConfig.name)
                    print("🔗 DEBUG: modelConfig.name=\(modelConfig.name), modelExists=\(modelExists), customModels=\(aiService.customModels)")
                    if !modelExists {
                        try installConfirmation(modelConfig, deferredChat: request)
                        DiagnosticsLogger.log(
                            .app,
                            level: .fault,
                            message: "🔗 DEBUG: Set pendingAddModel=\(String(describing: pendingAddModel)), pendingChat model=\(request.model ?? "nil")"
                        )
                        DiagnosticsLogger.log(
                            .app,
                            level: .info,
                            message: "🔗 Unified flow: add model then chat",
                            metadata: ["modelName": modelConfig.name, "hasPrompt": "\(request.prompt != nil)"]
                        )
                    } else {
                        enqueueReadyChat(request)
                        DiagnosticsLogger.log(
                            .app,
                            level: .info,
                            message: "🔗 Pending chat request (model exists)",
                            metadata: [
                                "model": request.model ?? "default",
                                "hasPrompt": "\(request.prompt != nil)"
                            ]
                        )
                    }
                } else {
                    try validateModelAvailability(for: request)
                    enqueueReadyChat(request)
                    DiagnosticsLogger.log(
                        .app,
                        level: .info,
                        message: "🔗 Pending chat request",
                        metadata: [
                            "model": request.model ?? "default",
                            "hasPrompt": "\(request.prompt != nil)"
                        ]
                    )
                }
            }
        } catch let error as DeepLinkError {
            errorMessage = error.errorDescription
            errorRecoverySuggestion = error.recoverySuggestion
            DiagnosticsLogger.log(
                .app,
                level: .error,
                message: "🔗 Deep link error",
                metadata: ["error": error.errorDescription ?? "Unknown"]
            )
        } catch {
            errorMessage = ErrorPresenter.userMessage(for: error)
            errorRecoverySuggestion = ErrorPresenter.recoverySuggestion(for: error)
            DiagnosticsLogger.log(
                .app,
                level: .error,
                message: "🔗 Deep link error",
                metadata: ["error": ErrorPresenter.userMessage(for: error)]
            )
        }
    }

    func confirmAddModel(expectedRequestID: UUID) {
        guard let confirmation = pendingConfirmation,
              let request = pendingAddModel,
              confirmation.request.id == request.id,
              request.id == expectedRequestID
        else { return }

        do {
            try addModelConfig(request)
            if let deferredChat = confirmation.deferredChat {
                readyChatQueue.append(deferredChat)
            }
            DiagnosticsLogger.log(
                .app,
                level: .info,
                message: "✅ Model added via deep link",
                metadata: ["modelName": request.name]
            )
        } catch let error as DeepLinkError {
            present(error)
        } catch {
            errorMessage = ErrorPresenter.userMessage(for: error)
            errorRecoverySuggestion = ErrorPresenter.recoverySuggestion(for: error)
        }

        pendingConfirmation = nil
        pendingAddModel = nil
    }

    func cancelAddModel(expectedRequestID: UUID) {
        guard let confirmation = pendingConfirmation,
              let request = pendingAddModel,
              confirmation.request.id == request.id,
              request.id == expectedRequestID
        else { return }

        pendingConfirmation = nil
        pendingAddModel = nil
        DiagnosticsLogger.log(
            .app,
            level: .info,
            message: "🔗 Add-model cancelled by user"
        )
    }

    func dismissError() {
        errorMessage = nil
        errorRecoverySuggestion = nil
    }

    func consumeNextReadyChat() -> ChatRequest? {
        popNextReadyChat()
    }

    private func enqueueReadyChat(_ request: ChatRequest) {
        readyChatQueue.append(request)
    }

    private func installConfirmation(_ request: AddModelRequest, deferredChat: ChatRequest?) throws {
        guard pendingConfirmation == nil else {
            throw DeepLinkError.confirmationInProgress
        }

        pendingConfirmation = PendingConfirmation(request: request, deferredChat: deferredChat)
        pendingAddModel = request
    }

    private func popNextReadyChat() -> ChatRequest? {
        while !readyChatQueue.isEmpty {
            let request = readyChatQueue.removeFirst()
            if isModelAvailable(for: request) {
                return request
            }
            present(DeepLinkError.modelNotFound(request.model ?? ""))
        }
        return nil
    }

    private func validateModelAvailability(for request: ChatRequest) throws {
        guard isModelAvailable(for: request) else {
            throw DeepLinkError.modelNotFound(request.model ?? "")
        }
    }

    private func isModelAvailable(for request: ChatRequest) -> Bool {
        guard let model = request.model else { return true }
        return aiService.customModels.contains(model)
    }

    private func present(_ error: DeepLinkError) {
        errorMessage = error.errorDescription
        errorRecoverySuggestion = error.recoverySuggestion
    }

    private func parseURL(_ url: URL) throws -> DeepLinkAction {
        guard url.scheme == "ayna" else {
            throw DeepLinkError.invalidURL
        }

        guard let host = url.host else {
            throw DeepLinkError.invalidURL
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw DeepLinkError.invalidURL
        }

        let params = extractParameters(from: components)

        switch host {
        case "add-model":
            return try parseAddModel(params: params)
        case "chat":
            return try parseChat(params: params)
        case "main":
            return .chat(ChatRequest(model: nil, prompt: nil, systemPrompt: nil, modelConfig: nil))
        default:
            throw DeepLinkError.unknownAction(host)
        }
    }

    private func extractParameters(from components: URLComponents) -> [String: String] {
        var params: [String: String] = [:]
        components.queryItems?.forEach { item in
            params[item.name] = item.value ?? ""
        }
        return params
    }

    private func parseAddModel(params: [String: String]) throws -> DeepLinkAction {
        guard let rawName = params["name"] else {
            throw DeepLinkError.missingRequiredParameter("name")
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw DeepLinkError.missingRequiredParameter("name") }

        let provider: AIProvider
        if let providerString = params["provider"] {
            let normalizedProvider = providerString.lowercased()
            switch normalizedProvider {
            case "openai", "open ai":
                provider = .openai
            case "anthropic":
                provider = .anthropic
            case "apple", "apple intelligence", "appleintelligence":
                provider = .appleIntelligence
            default:
                if let exactMatch = AIProvider.allCases.first(where: { $0.rawValue.lowercased() == normalizedProvider }) {
                    provider = exactMatch
                } else {
                    throw DeepLinkError.invalidProvider(providerString)
                }
            }
        } else {
            provider = .openai
        }

        let endpointType: APIEndpointType
        if let typeString = params["type"] {
            let normalizedType = typeString.lowercased()
            switch normalizedType {
            case "chat", "chatcompletions", "chat completions":
                endpointType = .chatCompletions
            case "responses", "response":
                endpointType = .responses
            case "image", "imagegeneration", "image generation":
                endpointType = .imageGeneration
            default:
                if let exactMatch = APIEndpointType.allCases.first(where: { $0.rawValue.lowercased() == normalizedType }) {
                    endpointType = exactMatch
                } else {
                    throw DeepLinkError.invalidEndpointType(typeString)
                }
            }
        } else {
            endpointType = .chatCompletions
        }

        let request = AddModelRequest(
            name: name,
            provider: provider,
            endpoint: params["endpoint"],
            apiKey: params["key"],
            endpointType: endpointType
        )

        return .addModel(request)
    }

    private func parseChat(params: [String: String]) throws -> DeepLinkAction {
        let model: String?
        if let rawModel = params["model"] {
            let trimmedModel = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedModel.isEmpty else {
                throw DeepLinkError.missingRequiredParameter("model")
            }
            model = trimmedModel
        } else {
            model = nil
        }

        var modelConfig: AddModelRequest?
        if let modelName = model {
            let hasConfigParams = params["provider"] != nil ||
                params["endpoint"] != nil ||
                params["key"] != nil ||
                params["type"] != nil

            if hasConfigParams {
                let provider: AIProvider
                if let providerString = params["provider"] {
                    let normalizedProvider = providerString.lowercased()
                    switch normalizedProvider {
                    case "openai", "open ai":
                        provider = .openai
                    case "anthropic":
                        provider = .anthropic
                    case "apple", "apple intelligence", "appleintelligence":
                        provider = .appleIntelligence
                    default:
                        if let exactMatch = AIProvider.allCases.first(where: { $0.rawValue.lowercased() == normalizedProvider }) {
                            provider = exactMatch
                        } else {
                            throw DeepLinkError.invalidProvider(providerString)
                        }
                    }
                } else {
                    provider = .openai
                }

                let endpointType: APIEndpointType
                if let typeString = params["type"] {
                    let normalizedType = typeString.lowercased()
                    switch normalizedType {
                    case "chat", "chatcompletions", "chat completions":
                        endpointType = .chatCompletions
                    case "responses", "response":
                        endpointType = .responses
                    case "image", "imagegeneration", "image generation":
                        endpointType = .imageGeneration
                    default:
                        if let exactMatch = APIEndpointType.allCases.first(where: { $0.rawValue.lowercased() == normalizedType }) {
                            endpointType = exactMatch
                        } else {
                            throw DeepLinkError.invalidEndpointType(typeString)
                        }
                    }
                } else {
                    endpointType = .chatCompletions
                }

                modelConfig = AddModelRequest(
                    name: modelName,
                    provider: provider,
                    endpoint: params["endpoint"],
                    apiKey: params["key"],
                    endpointType: endpointType
                )
            }
        }

        let request = ChatRequest(
            model: model,
            prompt: params["prompt"],
            systemPrompt: params["system"],
            modelConfig: modelConfig
        )
        return .chat(request)
    }

    private func addModelConfig(_ request: AddModelRequest) throws {
        if aiService.customModels.contains(request.name) {
            throw DeepLinkError.modelAlreadyExists(request.name)
        }

        aiService.customModels.append(request.name)
        aiService.modelProviders[request.name] = request.provider
        aiService.modelEndpointTypes[request.name] = request.endpointType

        if let endpoint = request.endpoint, !endpoint.isEmpty {
            aiService.modelEndpoints[request.name] = endpoint
        }

        if let apiKey = request.apiKey, !apiKey.isEmpty {
            aiService.modelAPIKeys[request.name] = apiKey
        }
    }
}

//
//  DeepLinkManager.swift
//  ayna
//
//  Created on 12/8/25.
//

import Combine
import Foundation
import OSLog
import SwiftUI

// MARK: - Deep Link Error

/// Errors that can occur during deep link handling
enum DeepLinkError: LocalizedError {
    case invalidURL
    case missingRequiredParameter(String)
    case invalidProvider(String)
    case invalidEndpointType(String)
    case modelAlreadyExists(String)
    case modelNotFound(String)
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
            "Valid providers: OpenAI, GitHub Models, Apple Intelligence"
        case .invalidEndpointType:
            "Valid types: Chat Completions, Responses, Image Generation"
        case .modelAlreadyExists:
            "Use a different model name or remove the existing model first"
        case .modelNotFound:
            "Check that the model name is correct"
        case .unknownAction:
            "Supported actions: add-model, chat"
        }
    }
}

// MARK: - Add Model Request

/// Request to add a new model configuration via deep link
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

// MARK: - Chat Request

/// Request to start a chat via deep link
struct ChatRequest: Equatable {
    let model: String?
    let prompt: String?
    let systemPrompt: String?
    /// Optional model configuration for unified add+chat flow
    let modelConfig: AddModelRequest?
}

// MARK: - Deep Link Action

/// Parsed deep link action
enum DeepLinkAction: Equatable {
    case addModel(AddModelRequest)
    case chat(ChatRequest)
    case oauthCallback(URL)
}

// MARK: - Deep Link Manager

/// Manages deep link URL handling for the Ayna app.
/// Supports:
/// - `ayna://add-model?name=...&provider=...&endpoint=...&key=...&type=...`
/// - `ayna://chat?model=...&prompt=...&system=...&provider=...&endpoint=...&key=...&type=...`
/// The chat action supports a unified flow: if model config params are provided and the model
/// doesn't exist, it will prompt to add the model first, then start the chat.
@MainActor
final class DeepLinkManager: ObservableObject {
    static let shared = DeepLinkManager()

    /// Pending add-model request awaiting user confirmation
    @Published var pendingAddModel: AddModelRequest?

    /// Pending chat request to be executed (stored while waiting for add-model confirmation)
    @Published var pendingChat: ChatRequest?

    /// Error message to display in error banner
    @Published var errorMessage: String?

    /// Recovery suggestion for the current error
    @Published var errorRecoverySuggestion: String?

    /// Whether a confirmation sheet should be shown
    var showAddModelConfirmation: Bool {
        pendingAddModel != nil
    }

    private let openAIService: OpenAIService

    init(openAIService: OpenAIService? = nil) {
        self.openAIService = openAIService ?? .shared
    }

    // MARK: - Public Methods

    /// Handle an incoming URL
    /// - Parameter url: The URL to handle
    /// - Returns: The parsed action, or nil if the URL couldn't be handled
    func handle(url: URL) async {
        DiagnosticsLogger.log(
            .app,
            level: .info,
            message: "🔗 Handling deep link",
            metadata: ["url": url.absoluteString]
        )

        // Clear any previous error
        errorMessage = nil
        errorRecoverySuggestion = nil

        do {
            let action = try parseURL(url)

            switch action {
            case let .addModel(request):
                // Show confirmation dialog instead of adding immediately
                pendingAddModel = request
                DiagnosticsLogger.log(
                    .app,
                    level: .info,
                    message: "🔗 Pending add-model confirmation",
                    metadata: ["modelName": request.name]
                )

            case let .chat(request):
                // Check if this is a unified flow (chat with model config)
                if let modelConfig = request.modelConfig {
                    let modelExists = openAIService.customModels.contains(modelConfig.name)
                    print("🔗 DEBUG: modelConfig.name=\(modelConfig.name), modelExists=\(modelExists), customModels=\(openAIService.customModels)")
                    if !modelExists {
                        // Model doesn't exist - show add confirmation first, store chat for after
                        pendingAddModel = modelConfig
                        pendingChat = request
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
                        // Model exists - proceed with chat directly
                        pendingChat = request
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
                    // No config provided - proceed with chat directly
                    pendingChat = request
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

            case let .oauthCallback(callbackURL):
                // Delegate to GitHubOAuthService
                await GitHubOAuthService.shared.handleCallbackURL(callbackURL)
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

    /// Confirm and execute the pending add-model request
    /// If there's a pending chat request, it will proceed after adding the model
    func confirmAddModel() {
        guard let request = pendingAddModel else { return }

        do {
            try addModelConfig(request)
            DiagnosticsLogger.log(
                .app,
                level: .info,
                message: "✅ Model added via deep link",
                metadata: ["modelName": request.name]
            )
            // Note: pendingChat is preserved so the chat can proceed
        } catch let error as DeepLinkError {
            errorMessage = error.errorDescription
            errorRecoverySuggestion = error.recoverySuggestion
            // Clear pending chat on error since the model wasn't added
            pendingChat = nil
        } catch {
            errorMessage = ErrorPresenter.userMessage(for: error)
            errorRecoverySuggestion = ErrorPresenter.recoverySuggestion(for: error)
            pendingChat = nil
        }

        pendingAddModel = nil
    }

    /// Cancel the pending add-model request
    /// Also clears any pending chat that was waiting for the model
    func cancelAddModel() {
        pendingAddModel = nil
        // Also clear pending chat if it was part of unified flow
        if pendingChat?.modelConfig != nil {
            pendingChat = nil
        }
        DiagnosticsLogger.log(
            .app,
            level: .info,
            message: "🔗 Add-model cancelled by user"
        )
    }

    /// Dismiss the current error
    func dismissError() {
        errorMessage = nil
        errorRecoverySuggestion = nil
    }

    /// Clear the pending chat request (after it's been processed)
    func clearPendingChat() {
        pendingChat = nil
    }

    // MARK: - Private Methods

    /// Parse a URL into a deep link action
    private func parseURL(_ url: URL) throws -> DeepLinkAction {
        guard url.scheme == "ayna" else {
            throw DeepLinkError.invalidURL
        }

        guard let host = url.host else {
            throw DeepLinkError.invalidURL
        }

        // Handle OAuth callbacks (GitHub auth)
        if host == "auth" || host == "callback" || url.path.contains("callback") {
            return .oauthCallback(url)
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
            // Internal action to open main window - no action needed, window will open
            return .chat(ChatRequest(model: nil, prompt: nil, systemPrompt: nil, modelConfig: nil))
        default:
            throw DeepLinkError.unknownAction(host)
        }
    }

    /// Extract query parameters from URL components
    private func extractParameters(from components: URLComponents) -> [String: String] {
        var params: [String: String] = [:]
        components.queryItems?.forEach { item in
            if let value = item.value {
                params[item.name] = value
            }
        }
        return params
    }

    /// Parse add-model action parameters
    private func parseAddModel(params: [String: String]) throws -> DeepLinkAction {
        // Name is required
        guard let name = params["name"], !name.isEmpty else {
            throw DeepLinkError.missingRequiredParameter("name")
        }

        // Provider (optional, defaults to OpenAI)
        let provider: AIProvider
        if let providerString = params["provider"] {
            // Try to match case-insensitively
            let normalizedProvider = providerString.lowercased()
            switch normalizedProvider {
            case "openai", "open ai":
                provider = .openai
            case "github", "github models", "githubmodels":
                provider = .githubModels
            case "apple", "apple intelligence", "appleintelligence":
                provider = .appleIntelligence
            default:
                // Try exact match
                if let exactMatch = AIProvider.allCases.first(where: { $0.rawValue.lowercased() == normalizedProvider }) {
                    provider = exactMatch
                } else {
                    throw DeepLinkError.invalidProvider(providerString)
                }
            }
        } else {
            provider = .openai
        }

        // Endpoint type (optional, defaults to chatCompletions)
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

    /// Parse chat action parameters
    /// Supports unified flow: if provider/endpoint/key/type params are present along with model,
    /// creates a model config that will be used to add the model if it doesn't exist
    private func parseChat(params: [String: String]) throws -> DeepLinkAction {
        let model = params["model"]

        // Check if model configuration params are provided (unified add+chat flow)
        var modelConfig: AddModelRequest?
        if let modelName = model {
            let hasConfigParams = params["provider"] != nil ||
                params["endpoint"] != nil ||
                params["key"] != nil ||
                params["type"] != nil

            if hasConfigParams {
                // Parse provider
                let provider: AIProvider
                if let providerString = params["provider"] {
                    let normalizedProvider = providerString.lowercased()
                    switch normalizedProvider {
                    case "openai", "open ai":
                        provider = .openai
                    case "github", "github models", "githubmodels":
                        provider = .githubModels
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

                // Parse endpoint type
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

    /// Add a model configuration from a request
    private func addModelConfig(_ request: AddModelRequest) throws {
        // Check if model already exists
        if openAIService.customModels.contains(request.name) {
            throw DeepLinkError.modelAlreadyExists(request.name)
        }

        // Add the model
        openAIService.customModels.append(request.name)
        openAIService.modelProviders[request.name] = request.provider
        openAIService.modelEndpointTypes[request.name] = request.endpointType

        // Set custom endpoint if provided
        if let endpoint = request.endpoint, !endpoint.isEmpty {
            openAIService.modelEndpoints[request.name] = endpoint
        }

        // Set API key if provided
        if let apiKey = request.apiKey, !apiKey.isEmpty {
            openAIService.modelAPIKeys[request.name] = apiKey
        }

        // Optionally select the new model as default
        // (We don't auto-select to avoid disrupting user's workflow)
    }
}

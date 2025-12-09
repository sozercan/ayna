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
            "Valid providers: OpenAI, GitHub Models, Apple Intelligence, AIKit"
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
/// - `ayna://chat?model=...&prompt=...&system=...`
@MainActor
final class DeepLinkManager: ObservableObject {
    static let shared = DeepLinkManager()

    /// Pending add-model request awaiting user confirmation
    @Published var pendingAddModel: AddModelRequest?

    /// Pending chat request to be executed
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

    init(openAIService: OpenAIService = .shared) {
        self.openAIService = openAIService
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
            errorMessage = error.localizedDescription
            DiagnosticsLogger.log(
                .app,
                level: .error,
                message: "🔗 Deep link error",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    /// Confirm and execute the pending add-model request
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
        } catch let error as DeepLinkError {
            errorMessage = error.errorDescription
            errorRecoverySuggestion = error.recoverySuggestion
        } catch {
            errorMessage = error.localizedDescription
        }

        pendingAddModel = nil
    }

    /// Cancel the pending add-model request
    func cancelAddModel() {
        pendingAddModel = nil
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
            return .chat(ChatRequest(model: nil, prompt: nil, systemPrompt: nil))
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
            case "aikit", "local":
                provider = .aikit
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
    private func parseChat(params: [String: String]) throws -> DeepLinkAction {
        let request = ChatRequest(
            model: params["model"],
            prompt: params["prompt"],
            systemPrompt: params["system"]
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

//
//  OpenAIService.swift
//  ayna
//
//  Created on 11/2/25.
//

import Foundation

enum AIProvider: String, CaseIterable, Codable {
    case openai = "OpenAI"
    case azure = "Azure OpenAI"

    var displayName: String { rawValue }
}

class OpenAIService: ObservableObject {
    static let shared = OpenAIService()

    @Published var apiKey: String {
        didSet {
            saveAPIKey()
        }
    }

    @Published var selectedModel: String {
        didSet {
            UserDefaults.standard.set(selectedModel, forKey: "selectedModel")
        }
    }

    let temperature: Double = 0.7

    @Published var provider: AIProvider {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: "aiProvider")
        }
    }

    // Azure OpenAI specific settings
    @Published var azureEndpoint: String {
        didSet {
            let trimmed = azureEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != azureEndpoint {
                azureEndpoint = trimmed
            }
            UserDefaults.standard.set(trimmed, forKey: "azureEndpoint")
        }
    }

    @Published var azureDeploymentName: String {
        didSet {
            let trimmed = azureDeploymentName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != azureDeploymentName {
                azureDeploymentName = trimmed
            }
            UserDefaults.standard.set(trimmed, forKey: "azureDeploymentName")
        }
    }

    @Published var azureAPIVersion: String {
        didSet {
            let trimmed = azureAPIVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != azureAPIVersion {
                azureAPIVersion = trimmed
            }
            UserDefaults.standard.set(trimmed, forKey: "azureAPIVersion")
        }
    }

    private let openAIURL = "https://api.openai.com/v1/chat/completions"

    @Published var customModels: [String] {
        didSet {
            UserDefaults.standard.set(customModels, forKey: "customModels")
        }
    }

    @Published var modelProviders: [String: AIProvider] {
        didSet {
            let encodedDict = modelProviders.mapValues { $0.rawValue }
            UserDefaults.standard.set(encodedDict, forKey: "modelProviders")
        }
    }

    let azureAPIVersions = [
        "2025-04-01-preview",
        "2025-03-01-preview",
        "2025-02-01-preview",
        "2025-01-01-preview",
        "2024-12-01-preview",
        "2024-10-21",
        "2024-10-01-preview",
        "2024-08-01-preview",
        "2024-06-01",
        "2024-05-01-preview",
        "2024-02-01",
        "2023-12-01-preview"
    ]

    // Image generation settings
    @Published var imageSize: String {
        didSet {
            UserDefaults.standard.set(imageSize, forKey: "imageSize")
        }
    }

    @Published var imageQuality: String {
        didSet {
            UserDefaults.standard.set(imageQuality, forKey: "imageQuality")
        }
    }

    @Published var outputFormat: String {
        didSet {
            UserDefaults.standard.set(outputFormat, forKey: "outputFormat")
        }
    }

    @Published var outputCompression: Int {
        didSet {
            UserDefaults.standard.set(outputCompression, forKey: "outputCompression")
        }
    }

    enum ModelCapability {
        case chat
        case imageGeneration
    }

    init() {
        // Load custom models first
        let loadedCustomModels: [String]
        if let savedModels = UserDefaults.standard.array(forKey: "customModels") as? [String], !savedModels.isEmpty {
            loadedCustomModels = savedModels
        } else {
            loadedCustomModels = ["gpt-4o", "gpt-4o-mini", "o1", "gpt-image-1"]
        }
        self.customModels = loadedCustomModels

        // Load model providers mapping
        if let savedProviders = UserDefaults.standard.dictionary(forKey: "modelProviders") as? [String: String] {
            self.modelProviders = savedProviders.compactMapValues { AIProvider(rawValue: $0) }
        } else {
            // Default all initial models to OpenAI
            self.modelProviders = Dictionary(uniqueKeysWithValues: loadedCustomModels.map { ($0, AIProvider.openai) })
        }

        // Load selected model, ensure it exists in custom models
        let savedSelectedModel = UserDefaults.standard.string(forKey: "selectedModel") ?? "gpt-4o"
        if loadedCustomModels.contains(savedSelectedModel) {
            self.selectedModel = savedSelectedModel
        } else {
            self.selectedModel = loadedCustomModels.first ?? "gpt-4o"
        }

        // Initialize API key
        self.apiKey = UserDefaults.standard.string(forKey: "openai_api_key") ?? ""

        // Initialize provider
        if let providerString = UserDefaults.standard.string(forKey: "aiProvider"),
           let savedProvider = AIProvider(rawValue: providerString) {
            self.provider = savedProvider
        } else {
            self.provider = .openai
        }

        // Initialize Azure settings
        self.azureEndpoint = (UserDefaults.standard.string(forKey: "azureEndpoint") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.azureDeploymentName = (UserDefaults.standard.string(forKey: "azureDeploymentName") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.azureAPIVersion = (UserDefaults.standard.string(forKey: "azureAPIVersion") ?? "2024-08-01-preview").trimmingCharacters(in: .whitespacesAndNewlines)

        // Initialize image generation settings
        self.imageSize = UserDefaults.standard.string(forKey: "imageSize") ?? "1024x1024"
        self.imageQuality = UserDefaults.standard.string(forKey: "imageQuality") ?? "medium"
        self.outputFormat = UserDefaults.standard.string(forKey: "outputFormat") ?? "png"
        self.outputCompression = UserDefaults.standard.integer(forKey: "outputCompression") == 0 ? 100 : UserDefaults.standard.integer(forKey: "outputCompression")
    }

    private func saveAPIKey() {
        UserDefaults.standard.set(apiKey, forKey: "openai_api_key")
    }

    private func getAPIURL(deploymentName: String? = nil) -> String {
        switch provider {
        case .openai:
            return openAIURL
        case .azure:
            // Azure OpenAI URL format: https://{endpoint}/openai/deployments/{deployment-name}/chat/completions?api-version={version}
            let cleanEndpoint = azureEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            // Use the provided deployment name (from conversation model) or fall back to the global setting
            let cleanDeployment = (deploymentName ?? azureDeploymentName).trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanVersion = azureAPIVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(cleanEndpoint)/openai/deployments/\(cleanDeployment)/chat/completions?api-version=\(cleanVersion)"
        }
    }

    func getModelCapability(_ model: String) -> ModelCapability {
        let lowercaseModel = model.lowercased()
        if lowercaseModel.contains("gpt-image") || lowercaseModel.contains("dall-e") {
            return .imageGeneration
        }
        return .chat
    }

    func generateImage(
        prompt: String,
        model: String? = nil,
        onComplete: @escaping (Data) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        print("🖼️ generateImage called - Model: \(model ?? selectedModel)")

        guard !apiKey.isEmpty else {
            print("❌ Missing API key")
            onError(OpenAIError.missingAPIKey)
            return
        }

        guard provider == .azure else {
            print("❌ Image generation only supported on Azure provider")
            onError(OpenAIError.unsupportedProvider)
            return
        }

        guard !azureEndpoint.isEmpty else {
            print("❌ Missing Azure endpoint")
            onError(OpenAIError.missingAzureEndpoint)
            return
        }

        let requestModel = model ?? selectedModel

        // Image generation endpoint: {endpoint}/openai/deployments/{model}/images/generations?api-version={version}
        let cleanEndpoint = azureEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanVersion = azureAPIVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageURL = "\(cleanEndpoint)/openai/deployments/\(requestModel)/images/generations?api-version=\(cleanVersion)"

        guard let url = URL(string: imageURL) else {
            print("❌ Invalid URL: \(imageURL)")
            onError(OpenAIError.invalidURL)
            return
        }

        print("✅ Sending image generation request to: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "prompt": prompt,
            "size": imageSize,
            "quality": imageQuality,
            "output_format": outputFormat,
            "output_compression": outputCompression,
            "n": 1
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            onError(error)
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("❌ Network error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    onError(error)
                }
                return
            }

            guard let data = data else {
                print("❌ No data received")
                DispatchQueue.main.async {
                    onError(OpenAIError.noData)
                }
                return
            }

            // Parse response
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // Check for error response
                    if let errorDict = json["error"] as? [String: Any],
                       let code = errorDict["code"] as? String,
                       let message = errorDict["message"] as? String {
                        print("❌ API error: \(code) - \(message)")
                        DispatchQueue.main.async {
                            if code == "contentFilter" {
                                onError(OpenAIError.contentFiltered(message))
                            } else {
                                onError(OpenAIError.apiError(message))
                            }
                        }
                        return
                    }

                    // Parse successful response: { "data": [{ "b64_json": "..." }] }
                    if let dataArray = json["data"] as? [[String: Any]],
                       let firstItem = dataArray.first,
                       let b64String = firstItem["b64_json"] as? String,
                       let imageData = Data(base64Encoded: b64String) {
                        print("✅ Image generated successfully, size: \(imageData.count) bytes")
                        DispatchQueue.main.async {
                            onComplete(imageData)
                        }
                    } else {
                        print("❌ Invalid response format")
                        DispatchQueue.main.async {
                            onError(OpenAIError.invalidResponse)
                        }
                    }
                }
            } catch {
                print("❌ JSON parsing error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    onError(error)
                }
            }
        }.resume()
    }

    func sendMessage(
        messages: [Message],
        model: String? = nil,
        temperature: Double? = nil,
        stream: Bool = true,
        tools: [[String: Any]]? = nil,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void,
        onToolCall: ((String, String, [String: Any]) async -> String)? = nil
    ) {
        print("🔵 sendMessage called - Provider: \(provider.displayName)")

        guard !apiKey.isEmpty else {
            print("❌ Missing API key")
            onError(OpenAIError.missingAPIKey)
            return
        }

        // Validate Azure settings if using Azure
        if provider == .azure {
            guard !azureEndpoint.isEmpty else {
                print("❌ Missing Azure endpoint")
                onError(OpenAIError.missingAzureEndpoint)
                return
            }
            guard !azureDeploymentName.isEmpty else {
                print("❌ Missing Azure deployment")
                onError(OpenAIError.missingAzureDeployment)
                return
            }
        }

        let requestModel = model ?? selectedModel
        let requestTemp = temperature ?? self.temperature

        // For Azure, use the conversation's model as the deployment name
        let apiURL = provider == .azure ? getAPIURL(deploymentName: requestModel) : getAPIURL()

        guard let url = URL(string: apiURL) else {
            print("❌ Invalid URL: \(apiURL)")
            onError(OpenAIError.invalidURL)
            return
        }

        print("✅ Sending request to: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Set authentication header based on provider
        switch provider {
        case .openai:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .azure:
            // Azure can use either api-key header OR Bearer token
            // Using Bearer token to match the working curl command
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let messagePayloads = messages.map { message in
            [
                "role": message.role.rawValue,
                "content": message.content
            ]
        }

        var body: [String: Any] = [
            "messages": messagePayloads,
            "stream": stream
        ]

        // Both OpenAI and Azure require model in body
        body["model"] = requestModel

        // Add tools if provided
        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // Debug: Print request details
        print("📤 REQUEST DEBUG:")
        print("   URL: \(url.absoluteString)")
        print("   Method: POST")
        print("   Provider: \(provider.displayName)")
        if let headers = request.allHTTPHeaderFields {
            print("   Headers:")
            for (key, value) in headers {
                if key == "Authorization" || key == "api-key" {
                    // Mask the actual key for security
                    let maskedValue = value.prefix(10) + "..." + value.suffix(4)
                    print("      \(key): \(maskedValue)")
                } else {
                    print("      \(key): \(value)")
                }
            }
        }
        if let bodyData = request.httpBody,
           let bodyString = String(data: bodyData, encoding: .utf8) {
            print("   Body: \(bodyString)")
        }

        if stream {
            streamResponse(request: request, onChunk: onChunk, onComplete: onComplete, onError: onError, onToolCall: onToolCall)
        } else {
            nonStreamResponse(request: request, onChunk: onChunk, onComplete: onComplete, onError: onError, onToolCall: onToolCall)
        }
    }

    private func streamResponse(
        request: URLRequest,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void,
        onToolCall: ((String, String, [String: Any]) async -> String)? = nil
    ) {
        // Capture values for async context
        let currentProvider = provider
        let currentModel = selectedModel
        let currentAzureDeployment = azureDeploymentName
        let currentAzureAPIVersion = azureAPIVersion
        let currentAzureEndpoint = azureEndpoint

        Task {
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    await MainActor.run {
                        onError(OpenAIError.invalidResponse)
                    }
                    return
                }

                print("� RESPONSE DEBUG:")
                print("   Status: \(httpResponse.statusCode)")
                if let headers = httpResponse.allHeaderFields as? [String: Any] {
                    print("   Headers:")
                    for (key, value) in headers {
                        print("      \(key): \(value)")
                    }
                }

                guard httpResponse.statusCode == 200 else {
                    // Provide helpful error messages
                    var errorMessage = "HTTP \(httpResponse.statusCode)"
                    if httpResponse.statusCode == 400 {
                        if currentProvider == .azure {
                            errorMessage += " - Invalid Azure deployment name '\(currentAzureDeployment)'. Check that this deployment exists in your Azure portal and supports the API version \(currentAzureAPIVersion)."
                        } else {
                            errorMessage += " - Invalid request. Check your model name and parameters."
                        }
                        print("❌ 400 Bad Request")
                        print("   Provider: \(currentProvider.displayName)")
                        if currentProvider == .azure {
                            print("   Deployment: \(currentAzureDeployment)")
                            print("   API Version: \(currentAzureAPIVersion)")
                            print("   Endpoint: \(currentAzureEndpoint)")
                        } else {
                            print("   Model: \(currentModel)")
                        }
                    }

                    // Try to read error response body
                    do {
                        var errorBody = ""
                        for try await byte in bytes {
                            if let char = String(data: Data([byte]), encoding: .utf8) {
                                errorBody += char
                            }
                        }
                        if !errorBody.isEmpty {
                            print("   Error Response Body: \(errorBody)")
                        }
                    } catch {
                        print("   Could not read error body: \(error)")
                    }

                    await MainActor.run {
                        onError(OpenAIError.apiError(errorMessage))
                    }
                    return
                }

                var buffer = Data()
                var toolCallBuffer: [String: Any] = [:]
                var toolCallId = ""

                for try await byte in bytes {
                    buffer.append(byte)

                    // Check if we have a newline (UTF-8: 0x0A)
                    if byte == 0x0A {
                        // Convert buffer to string
                        if let line = String(data: buffer, encoding: .utf8) {
                            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

                            if trimmedLine.hasPrefix("data: ") {
                                let jsonString = String(trimmedLine.dropFirst(6))

                                if jsonString == "[DONE]" {
                                    await MainActor.run {
                                        onComplete()
                                    }
                                    return
                                }

                                if let jsonData = jsonString.data(using: .utf8),
                                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                                   let choices = json["choices"] as? [[String: Any]],
                                   let firstChoice = choices.first,
                                   let delta = firstChoice["delta"] as? [String: Any] {

                                    // Handle regular content
                                    if let content = delta["content"] as? String {
                                        await MainActor.run {
                                            onChunk(content)
                                        }
                                    }

                                    // Handle tool calls
                                    if let toolCalls = delta["tool_calls"] as? [[String: Any]],
                                       let toolCall = toolCalls.first {
                                        if let id = toolCall["id"] as? String {
                                            toolCallId = id
                                        }
                                        if let function = toolCall["function"] as? [String: Any] {
                                            if let name = function["name"] as? String {
                                                toolCallBuffer["name"] = name
                                            }
                                            if let argsChunk = function["arguments"] as? String {
                                                let currentArgs = toolCallBuffer["arguments"] as? String ?? ""
                                                toolCallBuffer["arguments"] = currentArgs + argsChunk
                                            }
                                        }
                                    }

                                    // Check if tool call is complete
                                    if let finishReason = firstChoice["finish_reason"] as? String,
                                       finishReason == "tool_calls",
                                       let toolName = toolCallBuffer["name"] as? String,
                                       let argsString = toolCallBuffer["arguments"] as? String,
                                       let argsData = argsString.data(using: .utf8),
                                       let arguments = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any],
                                       let onToolCall = onToolCall {

                                        let result = await onToolCall(toolCallId, toolName, arguments)
                                        await MainActor.run {
                                            onChunk("\n\n[Tool: \(toolName)]\n\(result)\n")
                                        }

                                        // Clear buffer for next tool call
                                        toolCallBuffer = [:]
                                        toolCallId = ""
                                    }
                                }
                            }
                        }
                        buffer.removeAll()
                    }
                }

                await MainActor.run {
                    onComplete()
                }
            } catch {
                print("❌ Streaming error: \(error.localizedDescription)")
                await MainActor.run {
                    onError(error)
                }
            }
        }
    }

    private func nonStreamResponse(
        request: URLRequest,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void,
        onToolCall: ((String, String, [String: Any]) async -> String)? = nil
    ) {
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    onError(error)
                    return
                }

                guard let data = data else {
                    onError(OpenAIError.invalidResponse)
                    return
                }

                do {
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                    if let errorDict = json?["error"] as? [String: Any],
                       let message = errorDict["message"] as? String {
                        onError(OpenAIError.apiError(message))
                        return
                    }

                    if let choices = json?["choices"] as? [[String: Any]],
                       let firstChoice = choices.first,
                       let message = firstChoice["message"] as? [String: Any] {

                        // Handle regular content
                        if let content = message["content"] as? String {
                            onChunk(content)
                        }

                        // Handle tool calls
                        if let toolCalls = message["tool_calls"] as? [[String: Any]],
                           let onToolCall = onToolCall {
                            Task {
                                for toolCall in toolCalls {
                                    if let id = toolCall["id"] as? String,
                                       let function = toolCall["function"] as? [String: Any],
                                       let name = function["name"] as? String,
                                       let argsString = function["arguments"] as? String,
                                       let argsData = argsString.data(using: .utf8),
                                       let arguments = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {

                                        let result = await onToolCall(id, name, arguments)
                                        await MainActor.run {
                                            onChunk("\n\n[Tool: \(name)]\n\(result)\n")
                                        }
                                    }
                                }
                                await MainActor.run {
                                    onComplete()
                                }
                            }
                            return
                        }

                        onComplete()
                    } else {
                        onError(OpenAIError.invalidResponse)
                    }
                } catch {
                    onError(error)
                }
            }
        }

        task.resume()
    }

    enum OpenAIError: LocalizedError {
        case missingAPIKey
        case invalidResponse
        case apiError(String)
        case invalidURL
        case missingAzureEndpoint
        case missingAzureDeployment
        case unsupportedProvider
        case noData
        case contentFiltered(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Please add your API key in Settings"
            case .invalidResponse:
                return "Invalid response from API"
            case .apiError(let message):
                return message
            case .invalidURL:
                return "Invalid API endpoint URL"
            case .missingAzureEndpoint:
                return "Please configure Azure OpenAI endpoint in Settings"
            case .missingAzureDeployment:
                return "Please configure Azure deployment name in Settings"
            case .unsupportedProvider:
                return "Image generation is only supported with Azure OpenAI provider"
            case .noData:
                return "No data received from API"
            case .contentFiltered(let message):
                return "Content filtered: \(message)"
            }
        }
    }
}

// Keychain Helper


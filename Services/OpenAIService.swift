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
  case appleIntelligence = "Apple Intelligence"
  case aikit = "AIKit"

  var displayName: String { rawValue }
}

enum APIEndpointType: String, CaseIterable, Codable {
  case chatCompletions = "Chat Completions"
  case responses = "Responses"
  case imageGeneration = "Image Generation"

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
      // Sync with AIKitService if this is an AIKit model
      if modelProviders[selectedModel] == .aikit {
        AIKitService.shared.selectModelByName(selectedModel)
      }
    }
  }

  let temperature: Double = 0.7

  // Track current task for cancellation
  private var currentTask: URLSessionDataTask?

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

  // Custom URLSession with longer timeout for slow models
  private lazy var urlSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 120  // 2 minutes
    config.timeoutIntervalForResource = 300  // 5 minutes
    return URLSession(configuration: config)
  }()

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

  @Published var modelEndpointTypes: [String: APIEndpointType] {
    didSet {
      let encodedDict = modelEndpointTypes.mapValues { $0.rawValue }
      UserDefaults.standard.set(encodedDict, forKey: "modelEndpointTypes")
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
    if let savedModels = UserDefaults.standard.array(forKey: "customModels") as? [String],
      !savedModels.isEmpty {
      loadedCustomModels = savedModels
    } else {
      loadedCustomModels = ["gpt-4o", "gpt-4o-mini", "o1", "gpt-image-1"]
    }
    self.customModels = loadedCustomModels

    // Load model providers mapping
    if let savedProviders = UserDefaults.standard.dictionary(forKey: "modelProviders")
      as? [String: String] {
      self.modelProviders = savedProviders.compactMapValues { AIProvider(rawValue: $0) }
    } else {
      // Default all initial models to OpenAI
      self.modelProviders = Dictionary(
        uniqueKeysWithValues: loadedCustomModels.map { ($0, AIProvider.openai) })
    }

    // Load model endpoint types mapping
    if let savedEndpointTypes = UserDefaults.standard.dictionary(forKey: "modelEndpointTypes")
      as? [String: String] {
      self.modelEndpointTypes = savedEndpointTypes.compactMapValues { APIEndpointType(rawValue: $0) }
    } else {
      // Default all models to Chat Completions
      self.modelEndpointTypes = Dictionary(
        uniqueKeysWithValues: loadedCustomModels.map { ($0, APIEndpointType.chatCompletions) })
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
    self.azureEndpoint = (UserDefaults.standard.string(forKey: "azureEndpoint") ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    self.azureDeploymentName = (UserDefaults.standard.string(forKey: "azureDeploymentName") ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    self.azureAPIVersion =
      (UserDefaults.standard.string(forKey: "azureAPIVersion") ?? "2024-08-01-preview")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    // Initialize image generation settings
    self.imageSize = UserDefaults.standard.string(forKey: "imageSize") ?? "1024x1024"
    self.imageQuality = UserDefaults.standard.string(forKey: "imageQuality") ?? "medium"
    self.outputFormat = UserDefaults.standard.string(forKey: "outputFormat") ?? "png"
    self.outputCompression =
      UserDefaults.standard.integer(forKey: "outputCompression") == 0
      ? 100 : UserDefaults.standard.integer(forKey: "outputCompression")
  }

  private func saveAPIKey() {
    UserDefaults.standard.set(apiKey, forKey: "openai_api_key")
  }

  private func getAPIURL(deploymentName: String? = nil, provider: AIProvider? = nil) -> String {
    let effectiveProvider = provider ?? self.provider
    switch effectiveProvider {
    case .openai:
      return openAIURL
    case .azure:
      // Azure OpenAI URL format: https://{endpoint}/openai/deployments/{deployment-name}/chat/completions?api-version={version}
      let cleanEndpoint = azureEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      // Use the provided deployment name (from conversation model) or fall back to the global setting
      let cleanDeployment = (deploymentName ?? azureDeploymentName).trimmingCharacters(
        in: .whitespacesAndNewlines)
      let cleanVersion = azureAPIVersion.trimmingCharacters(in: .whitespacesAndNewlines)
      return
        "\(cleanEndpoint)/openai/deployments/\(cleanDeployment)/chat/completions?api-version=\(cleanVersion)"
    case .appleIntelligence:
      return "" // Not used for Apple Intelligence
    case .aikit:
      // AIKit provides OpenAI-compatible endpoint on localhost
      return "http://localhost:8080/v1/chat/completions"
    }
  }

  private func getResponsesAPIURL(deploymentName: String? = nil, provider: AIProvider? = nil) -> String {
    let effectiveProvider = provider ?? self.provider
    switch effectiveProvider {
    case .openai:
      return "https://api.openai.com/v1/responses"
    case .azure:
      // Azure OpenAI Responses API format: https://{endpoint}/openai/v1/responses
      let cleanEndpoint = azureEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      return "\(cleanEndpoint)/openai/v1/responses"
    case .appleIntelligence:
      return "" // Not used for Apple Intelligence
    case .aikit:
      // AIKit provides OpenAI-compatible endpoint on localhost
      return "http://localhost:8080/v1/responses"
    }
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

  func cancelCurrentRequest() {
    currentTask?.cancel()
    currentTask = nil
  }

  func generateImage(
    prompt: String,
    model: String? = nil,
    onComplete: @escaping (Data) -> Void,
    onError: @escaping (Error) -> Void
  ) {
    guard !apiKey.isEmpty else {
      onError(OpenAIError.missingAPIKey)
      return
    }

    guard provider == .azure else {
      onError(OpenAIError.unsupportedProvider)
      return
    }

    guard !azureEndpoint.isEmpty else {
      onError(OpenAIError.missingAzureEndpoint)
      return
    }

    let requestModel = model ?? selectedModel

    // Image generation endpoint: {endpoint}/openai/deployments/{model}/images/generations?api-version={version}
    let cleanEndpoint = azureEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let cleanVersion = azureAPIVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    let imageURL =
      "\(cleanEndpoint)/openai/deployments/\(requestModel)/images/generations?api-version=\(cleanVersion)"

    guard let url = URL(string: imageURL) else {
      onError(OpenAIError.invalidURL)
      return
    }

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

    urlSession.dataTask(with: request) { data, _, error in
      if let error = error {
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
            DispatchQueue.main.async {
              onComplete(imageData)
            }
          } else {
            DispatchQueue.main.async {
              onError(OpenAIError.invalidResponse)
            }
          }
        }
      } catch {
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
    conversationId: UUID? = nil,
    onChunk: @escaping (String) -> Void,
    onComplete: @escaping () -> Void,
    onError: @escaping (Error) -> Void,
    onToolCall: ((String, String, [String: Any]) async -> String)? = nil,
    onReasoning: ((String) -> Void)? = nil
  ) {
    let requestModel = model ?? selectedModel

    // Check if this specific model has a provider override
    let effectiveProvider = modelProviders[requestModel] ?? provider

    // Handle Apple Intelligence separately
    if effectiveProvider == .appleIntelligence {
      if #available(macOS 26.0, *) {
        handleAppleIntelligenceRequest(
          messages: messages,
          temperature: temperature,
          stream: stream,
          conversationId: conversationId,
          onChunk: onChunk,
          onComplete: onComplete,
          onError: onError
        )
      } else {
        onError(OpenAIError.apiError("Apple Intelligence requires macOS 26.0 or later"))
      }
      return
    }

    // Skip API key check for Apple Intelligence (handled above) and AIKit (local)
    if effectiveProvider != .aikit {
      guard !apiKey.isEmpty else {
        onError(OpenAIError.missingAPIKey)
        return
      }
    }

    // Validate Azure settings if using Azure
    if effectiveProvider == .azure {
      guard !azureEndpoint.isEmpty else {
        onError(OpenAIError.missingAzureEndpoint)
        return
      }
      guard !azureDeploymentName.isEmpty else {
        onError(OpenAIError.missingAzureDeployment)
        return
      }
    }

    let requestTemp = temperature ?? self.temperature

    // Check if this model should use the responses API based on endpoint type setting
    let endpointType = modelEndpointTypes[requestModel] ?? .chatCompletions

    if endpointType == .responses {
      // Use responses API
      responsesAPIRequest(
        messages: messages,
        model: requestModel,
        onChunk: onChunk,
        onComplete: onComplete,
        onError: onError,
        onReasoning: onReasoning
      )
      return
    }

    // For Azure, use the conversation's model as the deployment name
    let apiURL = effectiveProvider == .azure ? getAPIURL(deploymentName: requestModel, provider: effectiveProvider) : getAPIURL(provider: effectiveProvider)

    guard let url = URL(string: apiURL) else {
      onError(OpenAIError.invalidURL)
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    // Set authentication header based on provider
    switch effectiveProvider {
    case .openai:
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    case .azure:
      // Azure can use either api-key header OR Bearer token
      // Using Bearer token to match the working curl command
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    case .appleIntelligence:
      break // No authentication needed for Apple Intelligence
    case .aikit:
      break  // No authentication needed for local AIKit containers
    }

    let messagePayloads: [[String: Any]] = messages.map { message in
      var payload: [String: Any] = ["role": message.role.rawValue]

      // Check if message has attachments (multimodal content)
      if let attachments = message.attachments, !attachments.isEmpty {
        var contentArray: [[String: Any]] = []

        // Add text content if present
        if !message.content.isEmpty {
          contentArray.append([
            "type": "text",
            "text": message.content
          ])
        }

        // Add image attachments
        for attachment in attachments where attachment.mimeType.starts(with: "image/") {
          let base64Image = attachment.data.base64EncodedString()
          contentArray.append([
            "type": "image_url",
            "image_url": [
              "url": "data:\(attachment.mimeType);base64,\(base64Image)"
            ]
          ])
        }

        payload["content"] = contentArray
      } else {
        // Simple text content
        payload["content"] = message.content
      }

      return payload
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

    if stream {
      streamResponse(
        request: request, onChunk: onChunk, onComplete: onComplete, onError: onError,
        onToolCall: onToolCall, onReasoning: onReasoning)
    } else {
      nonStreamResponse(
        request: request, onChunk: onChunk, onComplete: onComplete, onError: onError,
        onToolCall: onToolCall, onReasoning: onReasoning)
    }
  }

  private func responsesAPIRequest(
    messages: [Message],
    model: String,
    onChunk: @escaping (String) -> Void,
    onComplete: @escaping () -> Void,
    onError: @escaping (Error) -> Void,
    onReasoning: ((String) -> Void)? = nil
  ) {
    // Check if this model has a provider override
    let effectiveProvider = modelProviders[model] ?? provider

    // Apple Intelligence doesn't support the responses API
    if effectiveProvider == .appleIntelligence {
      onError(OpenAIError.apiError("Apple Intelligence doesn't support the Responses API endpoint"))
      return
    }

    let apiURL = getResponsesAPIURL(provider: effectiveProvider)

    guard let url = URL(string: apiURL) else {
      onError(OpenAIError.invalidURL)
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    // Build input array with proper multimodal support
    var inputArray: [[String: Any]] = []

    for message in messages {
      // Skip system messages or handle them as instructions
      if message.role == .system {
        continue
      }

      // Create message item in Responses API format
      // Format for user: { "type": "message", "role": "user", "content": [{ "type": "input_text", "text": "..." }, { "type": "input_image", "image_url": "..." }] }
      // Format for assistant: { "type": "message", "role": "assistant", "content": [{ "type": "output_text", "text": "..." }] }
      var messageItem: [String: Any] = [
        "type": "message",
        "role": message.role.rawValue
      ]

      var contentArray: [[String: Any]] = []

      // Add text content if present
      // Use correct content type based on role: input_text for user, output_text for assistant
      if !message.content.isEmpty {
        let contentType = message.role == .user ? "input_text" : "output_text"
        contentArray.append([
          "type": contentType,
          "text": message.content
        ])
      }

      // Add image attachments with proper format for Responses API
      // Note: Images are only valid for user messages in the Responses API
      if let attachments = message.attachments, !attachments.isEmpty, message.role == .user {
        for attachment in attachments where attachment.mimeType.starts(with: "image/") {
          let base64Data = attachment.data.base64EncodedString()
          contentArray.append([
            "type": "input_image",
            "image_url": "data:\(attachment.mimeType);base64,\(base64Data)"
          ])
        }
      }

      messageItem["content"] = contentArray
      inputArray.append(messageItem)
    }

    var body: [String: Any] = [
      "model": model,
      "input": inputArray,
      "reasoning": ["summary": "auto"],
      "text": ["verbosity": "medium"]
    ]

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    } catch {
      onError(error)
      return
    }

    let task = urlSession.dataTask(with: request) { [weak self] data, _, error in
      DispatchQueue.main.async {
        // Clear the task reference
        self?.currentTask = nil

        if let error = error {
          // Don't report error if it was cancelled
          if (error as NSError).code == NSURLErrorCancelled {
            return
          }
          onError(error)
          return
        }

        guard let data = data else {
          onError(OpenAIError.noData)
          return
        }

        do {
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

          if let errorDict = json?["error"] as? [String: Any],
            let message = errorDict["message"] as? String {
            onError(OpenAIError.apiError(message))
            return
          }

          // Parse responses API format
          // Structure: { "output": [{ "type": "message" | "reasoning", "content": [...] }], "reasoning": { "summary": "...", "effort": "..." } }

          // Extract from output array
          if let outputArray = json?["output"] as? [[String: Any]] {
            for outputItem in outputArray {
              let itemType = outputItem["type"] as? String

              // Handle reasoning items - summary is an array of content parts
              if itemType == "reasoning" {
                if let summaryArray = outputItem["summary"] as? [[String: Any]],
                  let onReasoning = onReasoning {
                  for summaryPart in summaryArray {
                    if let type = summaryPart["type"] as? String,
                      type == "summary_text",
                      let text = summaryPart["text"] as? String {
                      onReasoning(text)
                    }
                  }
                }
              }
              // Handle message items
              else if itemType == "message" {
                if let content = outputItem["content"] as? [[String: Any]] {
                  for contentPart in content {
                    if let type = contentPart["type"] as? String, type == "output_text",
                      let text = contentPart["text"] as? String {
                      onChunk(text)
                    }
                  }
                }
              }
            }
          }

          onComplete()
        } catch {
          onError(error)
        }
      }
    }

    // Store and start the task
    currentTask = task
    task.resume()
  }

  private func streamResponse(
    request: URLRequest,
    onChunk: @escaping (String) -> Void,
    onComplete: @escaping () -> Void,
    onError: @escaping (Error) -> Void,
    onToolCall: ((String, String, [String: Any]) async -> String)? = nil,
    onReasoning: ((String) -> Void)? = nil
  ) {
    // Capture values for async context
    let currentProvider = provider
    let currentModel = selectedModel
    let currentAzureDeployment = azureDeploymentName
    let currentAzureAPIVersion = azureAPIVersion
    let currentAzureEndpoint = azureEndpoint

    Task {
      do {
        let (bytes, response) = try await urlSession.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
          await MainActor.run {
            onError(OpenAIError.invalidResponse)
          }
          return
        }

        guard httpResponse.statusCode == 200 else {
          // Provide helpful error messages
          var errorMessage = "HTTP \(httpResponse.statusCode)"
          if httpResponse.statusCode == 400 {
            if currentProvider == .azure {
              errorMessage +=
                " - Invalid Azure deployment name '\(currentAzureDeployment)'. Check that this deployment exists in your Azure portal and supports the API version \(currentAzureAPIVersion)."
            } else {
              errorMessage += " - Invalid request. Check your model name and parameters."
            }
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

                  // Handle reasoning content (for o1/o3 models)
                  // Try multiple possible field names
                  let reasoningContent =
                    delta["reasoning_content"] as? String ?? delta["reasoning"] as? String ?? delta[
                      "thought"] as? String

                  if let reasoning = reasoningContent, let onReasoning = onReasoning {
                    await MainActor.run {
                      onReasoning(reasoning)
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
                    let arguments = try? JSONSerialization.jsonObject(with: argsData)
                      as? [String: Any],
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
        await MainActor.run {
          // Check if it's a timeout error and provide a better message
          if let urlError = error as? URLError, urlError.code == .timedOut {
            onError(
              OpenAIError.apiError(
                "Request timed out. The model may be slow or overloaded. Please try again."))
          } else if let urlError = error as? URLError, urlError.code == .networkConnectionLost {
            onError(
              OpenAIError.apiError(
                "Network connection was lost. The server may have rejected the request."))
          } else {
            onError(error)
          }
        }
      }
    }
  }

  private func nonStreamResponse(
    request: URLRequest,
    onChunk: @escaping (String) -> Void,
    onComplete: @escaping () -> Void,
    onError: @escaping (Error) -> Void,
    onToolCall: ((String, String, [String: Any]) async -> String)? = nil,
    onReasoning: ((String) -> Void)? = nil
  ) {
    let task = urlSession.dataTask(with: request) { data, _, error in
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

            // Check for reasoning in various possible locations
            var foundReasoning: String?
            if let reasoning = message["reasoning"] as? String {
              foundReasoning = reasoning
            } else if let reasoning = message["reasoning_content"] as? String {
              foundReasoning = reasoning
            } else if let usage = json?["usage"] as? [String: Any],
              let details = usage["completion_tokens_details"] as? [String: Any],
              let reasoningTokens = details["reasoning_tokens"] as? Int, reasoningTokens > 0 {
              // Show reasoning token count
              foundReasoning = "💭 Reasoning tokens used: \(reasoningTokens)"
            }

            // Handle reasoning content if found
            if let reasoning = foundReasoning, let onReasoning = onReasoning {
              onReasoning(reasoning)
            }

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
                    let arguments = try? JSONSerialization.jsonObject(with: argsData)
                      as? [String: Any] {

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

  @available(macOS 26.0, *)
  private func handleAppleIntelligenceRequest(
    messages: [Message],
    temperature: Double?,
    stream: Bool,
    conversationId: UUID?,
    onChunk: @escaping (String) -> Void,
    onComplete: @escaping () -> Void,
    onError: @escaping (Error) -> Void
  ) {
    let service = AppleIntelligenceService.shared

    // Check availability
    guard service.isAvailable else {
      onError(OpenAIError.apiError(service.availabilityDescription()))
      return
    }

    // Extract system instructions (first system message if any)
    let systemInstructions =
      messages.first(where: { $0.role == .system })?.content
      ?? "You are a helpful assistant."

    // Get the last user message as the prompt
    guard let lastUserMessage = messages.last(where: { $0.role == .user }) else {
      onError(OpenAIError.apiError("No user message found"))
      return
    }

    // Use the provided conversation ID or a default
    let convId = conversationId?.uuidString ?? "default"

    let requestTemp = temperature ?? self.temperature

    Task {
      if stream {
        await service.streamResponse(
          conversationId: convId,
          prompt: lastUserMessage.content,
          systemInstructions: systemInstructions,
          temperature: requestTemp,
          onChunk: { chunk in
            onChunk(chunk)
          },
          onComplete: {
            onComplete()
          },
          onError: { error in
            onError(error)
          }
        )
      } else {
        await service.generateResponse(
          conversationId: convId,
          prompt: lastUserMessage.content,
          systemInstructions: systemInstructions,
          temperature: requestTemp,
          onComplete: { response in
            onChunk(response)
            onComplete()
          },
          onError: { error in
            onError(error)
          }
        )
      }
    }
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

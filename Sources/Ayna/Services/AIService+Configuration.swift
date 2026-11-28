import Foundation
import ImageIO
import UniformTypeIdentifiers

extension AIService {
    struct InitialConfiguration {
        let unrecognizedProviderValues: [String: String]
        let unrecognizedDefaultProviderValue: String?
        let modelsInheritingUnrecognizedDefaultProvider: Set<String>
        let customModels: [String]
        let modelProviders: [String: AIProvider]
        let modelEndpointTypes: [String: APIEndpointType]
        let modelEndpoints: [String: String]
        let modelThinkingBudgets: [String: Int]
        let modelAPIKeys: [String: String]
        let keychainLoadSucceeded: Bool
        let selectedModel: String
        let provider: AIProvider
        let imageSize: String
        let imageQuality: String
        let outputFormat: String
        let outputCompression: Int
    }

    static func loadInitialConfiguration(isUITesting: Bool) -> InitialConfiguration {
        let testModelName = "ui-test-model"
        let savedProviderValues = AppPreferences.storage.dictionary(forKey: "modelProviders") as? [String: String]
        let savedDefaultProviderValue = AppPreferences.storage.string(forKey: "aiProvider")
        let savedCustomModels = AppPreferences.storage.array(forKey: "customModels") as? [String] ?? []
        let savedEndpointTypeValues = AppPreferences.storage.dictionary(forKey: "modelEndpointTypes") as? [String: String]
        let savedEndpointValues = AppPreferences.storage.dictionary(forKey: "modelEndpoints") as? [String: String]
        let savedThinkingBudgetValues = AppPreferences.storage.dictionary(forKey: "modelThinkingBudgets") as? [String: Int]

        let unrecognizedProviders = savedProviderValues?.filter {
            AIProvider(rawValue: $0.value) == nil
        } ?? [:]

        var unrecognizedDefault: String?
        var inheritingUnrecognized: Set<String> = []
        if let savedDefaultProviderValue, AIProvider(rawValue: savedDefaultProviderValue) == nil {
            unrecognizedDefault = savedDefaultProviderValue
            inheritingUnrecognized = Set(savedCustomModels.filter { savedProviderValues?[$0] == nil })
        }

        var loadedCustomModels = savedCustomModels
        if isUITesting, !loadedCustomModels.contains(testModelName) {
            loadedCustomModels.insert(testModelName, at: 0)
        }

        let updatedProviders = loadModelProviders(
            savedProviderValues: savedProviderValues,
            loadedCustomModels: loadedCustomModels,
            isUITesting: isUITesting,
            testModelName: testModelName
        )
        let updatedEndpointTypes = loadModelEndpointTypes(
            savedEndpointTypeValues: savedEndpointTypeValues,
            loadedCustomModels: loadedCustomModels,
            isUITesting: isUITesting,
            testModelName: testModelName
        )
        let (loadedAPIKeys, loadSuccess) = loadModelAPIKeys()
        var mutableAPIKeys = loadedAPIKeys
        if isUITesting, mutableAPIKeys[testModelName]?.isEmpty ?? true {
            mutableAPIKeys[testModelName] = "ui-test-api-key"
        }

        let selectedModel = resolveInitialSelectedModel(
            savedCustomModels: savedCustomModels,
            savedProviderValues: savedProviderValues,
            savedDefaultProviderValue: savedDefaultProviderValue,
            isUITesting: isUITesting,
            testModelName: testModelName
        )
        let resolvedDefaultProvider = savedDefaultProviderValue.flatMap(AIProvider.init(rawValue:)) ?? .openai
        let storedCompression = AppPreferences.storage.integer(forKey: "outputCompression")

        return InitialConfiguration(
            unrecognizedProviderValues: unrecognizedProviders,
            unrecognizedDefaultProviderValue: unrecognizedDefault,
            modelsInheritingUnrecognizedDefaultProvider: inheritingUnrecognized,
            customModels: loadedCustomModels,
            modelProviders: updatedProviders,
            modelEndpointTypes: updatedEndpointTypes,
            modelEndpoints: savedEndpointValues ?? [:],
            modelThinkingBudgets: savedThinkingBudgetValues?.filter {
                $0.value >= AnthropicThinkingBudget.minimumBudgetTokens
            } ?? [:],
            modelAPIKeys: mutableAPIKeys,
            keychainLoadSucceeded: loadSuccess,
            selectedModel: selectedModel,
            provider: resolvedDefaultProvider,
            imageSize: AppPreferences.storage.string(forKey: "imageSize") ?? "1024x1024",
            imageQuality: AppPreferences.storage.string(forKey: "imageQuality") ?? "medium",
            outputFormat: AppPreferences.storage.string(forKey: "outputFormat") ?? "png",
            outputCompression: storedCompression == 0 ? 100 : storedCompression
        )
    }

    private static func loadModelProviders(
        savedProviderValues: [String: String]?,
        loadedCustomModels: [String],
        isUITesting: Bool,
        testModelName: String
    ) -> [String: AIProvider] {
        var loadedProviders: [String: AIProvider]
        if let savedProviders = savedProviderValues {
            let mapped = savedProviders.compactMapValues { AIProvider(rawValue: $0) }
            let droppedProviders = savedProviders.keys.filter { mapped[$0] == nil }
            if !droppedProviders.isEmpty {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .error,
                    message: "Ignored unrecognized provider mappings during load — models may appear reset",
                    metadata: [
                        "droppedModels": droppedProviders.joined(separator: ", "),
                        "rawValues": droppedProviders.compactMap { savedProviders[$0] }.joined(separator: ", ")
                    ]
                )
            }
            loadedProviders = mapped
        } else {
            loadedProviders = Dictionary(
                loadedCustomModels.map { ($0, AIProvider.openai) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        if isUITesting, loadedProviders[testModelName] == nil {
            loadedProviders[testModelName] = .openai
        }
        return loadedProviders
    }

    private static func loadModelEndpointTypes(
        savedEndpointTypeValues: [String: String]?,
        loadedCustomModels: [String],
        isUITesting: Bool,
        testModelName: String
    ) -> [String: APIEndpointType] {
        var loadedEndpointTypes: [String: APIEndpointType]
        if let savedEndpointTypes = savedEndpointTypeValues {
            let mapped = savedEndpointTypes.compactMapValues { APIEndpointType(rawValue: $0) }
            let droppedTypes = savedEndpointTypes.keys.filter { mapped[$0] == nil }
            if !droppedTypes.isEmpty {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .error,
                    message: "Dropped unrecognized endpoint type mappings during load — models may appear reset",
                    metadata: [
                        "droppedModels": droppedTypes.joined(separator: ", "),
                        "rawValues": droppedTypes.compactMap { savedEndpointTypes[$0] }.joined(separator: ", ")
                    ]
                )
            }
            loadedEndpointTypes = mapped
        } else {
            loadedEndpointTypes = Dictionary(
                loadedCustomModels.map { ($0, APIEndpointType.chatCompletions) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        if isUITesting, loadedEndpointTypes[testModelName] == nil {
            loadedEndpointTypes[testModelName] = .chatCompletions
        }
        return loadedEndpointTypes
    }

    private static func resolveInitialSelectedModel(
        savedCustomModels: [String],
        savedProviderValues: [String: String]?,
        savedDefaultProviderValue: String?,
        isUITesting: Bool,
        testModelName: String
    ) -> String {
        if isUITesting {
            return testModelName
        }
        let savedSelectedModel = AppPreferences.storage.string(forKey: "selectedModel") ?? ""
        let defaultProviderIsRecognized = savedDefaultProviderValue.map { AIProvider(rawValue: $0) != nil } ?? true
        let supportedCustomModels = savedCustomModels.filter { model in
            if let rawValue = savedProviderValues?[model] {
                return AIProvider(rawValue: rawValue) != nil
            }
            return defaultProviderIsRecognized
        }
        if supportedCustomModels.contains(savedSelectedModel) {
            return savedSelectedModel
        }
        return supportedCustomModels.first ?? ""
    }

    #if !os(watchOS)
        func persistModelProviders() {
            var encodedProviders = modelProviders.mapValues(\.rawValue)
            for (model, rawValue) in unrecognizedProviderValues where customModels.contains(model) {
                encodedProviders[model] = rawValue
            }
            AppPreferences.storage.set(encodedProviders, forKey: "modelProviders")
        }
    #endif

    func persistModelAPIKeys() {
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

    static func loadModelAPIKeys() -> (keys: [String: String], success: Bool) {
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

    func normalizedModelName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    func thinkingBudget(for modelName: String?) -> Int? {
        guard let normalizedName = normalizedModelName(modelName),
              let budget = modelThinkingBudgets[normalizedName],
              budget >= AnthropicThinkingBudget.minimumBudgetTokens
        else {
            return nil
        }

        return budget
    }

    func customEndpoint(for modelName: String?) -> (endpoint: String, model: String)? {
        guard let normalizedName = normalizedModelName(modelName),
              let endpoint = modelEndpoints[normalizedName]?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !endpoint.isEmpty
        else {
            return nil
        }

        return (endpoint, normalizedName)
    }

    func isAzureEndpoint(_ endpoint: String?) -> Bool {
        OpenAIEndpointResolver.isAzureEndpoint(endpoint)
    }

    func getAPIKey(for model: String?) -> String {
        guard let model else { return "" }
        return modelAPIKeys[model] ?? ""
    }

    func unrecognizedProviderName(for model: String) -> String? {
        if let rawValue = unrecognizedProviderValues[model] {
            return rawValue
        }
        guard modelsInheritingUnrecognizedDefaultProvider.contains(model) else {
            return nil
        }
        return unrecognizedDefaultProviderValue
    }

    func resolvedProvider(for model: String) throws -> AIProvider {
        if let providerName = unrecognizedProviderName(for: model) {
            throw AynaError.unsupportedProvider(
                provider: providerName,
                operation: "Using model '\(model)'"
            )
        }
        return modelProviders[model] ?? provider
    }

    func getAPIURL(deploymentName: String? = nil, provider: AIProvider? = nil) throws -> String {
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

    func getResponsesAPIURL(deploymentName: String? = nil, provider: AIProvider? = nil) throws -> String {
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

    #if !os(watchOS)
        var hasImageModelWithOutputOptions: Bool {
            customModels.contains { model in
                getModelCapability(model) == .imageGeneration
                    && OpenAIImageService.supportsOutputOptions(model: model)
            }
        }
    #endif

    func getModelCapability(_ model: String) -> ModelCapability {
        if let endpointType = modelEndpointTypes[model] {
            switch endpointType {
            case .imageGeneration:
                return .imageGeneration
            case .chatCompletions, .responses:
                return .chat
            }
        }
        return .chat
    }

    func validateProviderSettings(for provider: AIProvider, model: String?) throws {
        guard requiresAPIKey(for: provider, model: model) else { return }

        if !isAPIKeyConfigured(for: provider, model: model) {
            throw AynaError.missingAPIKey(provider: provider.displayName)
        }
    }

    func attachmentSupportError(for models: [String]) -> String? {
        for model in models {
            let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedModel.isEmpty,
                  getModelCapability(normalizedModel) != .imageGeneration
            else { continue }

            let modelProvider = modelProviders[normalizedModel] ?? provider
            if modelProvider == .appleIntelligence {
                return "Apple Intelligence does not support attachments. Choose a vision-capable cloud model."
            }
        }
        return nil
    }

    func attachmentHistorySupportError(for models: [String], messages: [Message]) -> String? {
        let normalizedModels = models
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let usesImageModel = normalizedModels.contains { getModelCapability($0) == .imageGeneration }
        if usesImageModel,
           let error = imageEditInputError(for: messages.last(where: { $0.role == .user }))
        {
            return error
        }

        guard messages.contains(where: { $0.attachments?.isEmpty == false }) else { return nil }
        return attachmentSupportError(for: normalizedModels)
    }

    private func imageEditInputError(for userMessage: Message?) -> String? {
        let attachments = userMessage?.attachments ?? []
        guard !attachments.isEmpty else { return nil }

        if let unsupported = attachments.first(where: {
            !OpenAIImageService.isEditableImageMIMEType($0.mimeType)
        }) {
            return "Image generation models accept only PNG, JPEG, or WebP image attachments. Remove \"\(unsupported.fileName)\" or choose a chat model."
        }
        if attachments.count > OpenAIImageService.maxSourceImages {
            return "Image generation supports at most \(OpenAIImageService.maxSourceImages) input images. Remove some images and try again."
        }
        if userMessage?.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return "Describe how to edit the attached image."
        }
        return nil
    }

    func attachmentImageLimitError(for models: [String], messages: [Message]) -> String? {
        guard usesAnthropicModel(models) else { return nil }

        let imageCount = messages.reduce(into: 0) { count, message in
            guard message.role == .user else { return }
            count += message.attachments?.count(where: {
                $0.mimeType.lowercased().hasPrefix("image/")
            }) ?? 0
        }
        guard imageCount > AnthropicRequestBuilder.maxImagesPerRequest else { return nil }

        return "Anthropic supports at most \(AnthropicRequestBuilder.maxImagesPerRequest) images per request. Remove some images or start a new conversation."
    }

    func attachmentImageValidationError(
        for models: [String],
        inMemoryAttachments attachments: [Message.FileAttachment]
    ) async -> String? {
        await attachmentImageValidationError(
            for: models,
            loading: attachments,
            loadAttachmentData: { _ in nil }
        )
    }

    func attachmentImageValidationError(
        for models: [String],
        loading attachments: [Message.FileAttachment],
        loadAttachmentData: @Sendable (String) async -> Data?
    ) async -> String? {
        let appliesAnthropicPolicy = usesAnthropicModel(models)

        for attachment in imageAttachments(in: attachments) {
            guard !Task.isCancelled else { return nil }
            let data: Data? = if let inlineData = attachment.data {
                inlineData
            } else if let localPath = attachment.localPath {
                await loadAttachmentData(localPath)
            } else {
                nil
            }
            guard let data else {
                return "Unable to load image attachment \"\(attachment.fileName)\". Remove it and try again."
            }
            if appliesAnthropicPolicy,
               let validationError = AnthropicRequestBuilder.imageValidationError(data: data)
            {
                return "\(attachment.fileName): \(validationError)"
            }

            let validationTask = Task.detached(priority: .utility) {
                Self.providerImageValidationError(
                    data: data,
                    declaredMimeType: attachment.mimeType
                )
            }
            let validationError = await withTaskCancellationHandler {
                await validationTask.value
            } onCancel: {
                validationTask.cancel()
            }
            guard !Task.isCancelled else { return nil }
            if let validationError {
                return "\(attachment.fileName): \(validationError)"
            }
        }
        return nil
    }

    func attachmentImageValidationError(
        for models: [String],
        in messages: [Message],
        loadAttachmentData: @Sendable (String) async -> Data?
    ) async -> String? {
        let validatedMessages = usesOnlyImageGenerationModels(models)
            ? Array(messages.last(where: { $0.role == .user }).map { [$0] } ?? [])
            : messages
        let attachments = validatedMessages.reduce(into: [Message.FileAttachment]()) { result, message in
            guard message.role == .user else { return }
            result.append(contentsOf: message.attachments ?? [])
        }
        return await attachmentImageValidationError(
            for: models,
            loading: attachments,
            loadAttachmentData: loadAttachmentData
        )
    }

    private func usesOnlyImageGenerationModels(_ models: [String]) -> Bool {
        let normalizedModels = models
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return !normalizedModels.isEmpty
            && normalizedModels.allSatisfy { getModelCapability($0) == .imageGeneration }
    }

    private func usesAnthropicModel(_ models: [String]) -> Bool {
        models.contains { model in
            let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedModel.isEmpty else { return false }
            return (modelProviders[normalizedModel] ?? provider) == .anthropic
        }
    }

    private func imageAttachments(
        in attachments: [Message.FileAttachment]
    ) -> [Message.FileAttachment] {
        attachments.filter { $0.mimeType.lowercased().hasPrefix("image/") }
    }

    private nonisolated static func providerImageValidationError(
        data: Data,
        declaredMimeType: String
    ) -> String? {
        guard !Task.isCancelled,
              !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else {
            return "Image data is invalid or corrupted."
        }

        let decodedContentType = CGImageSourceGetType(source)
            .flatMap { UTType($0 as String) }
        guard let decodedContentType,
              let decodedFormat = providerImageFormat(for: decodedContentType),
              let declaredContentType = UTType(mimeType: declaredMimeType),
              let declaredFormat = providerImageFormat(for: declaredContentType)
        else {
            return "Unsupported image format. Supported: JPEG, PNG, GIF, WebP"
        }
        guard decodedFormat == declaredFormat else {
            return "Image data does not match the declared \(declaredMimeType) format."
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard !Task.isCancelled,
              CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
        else {
            return Task.isCancelled ? nil : "Image data is invalid or corrupted."
        }
        return nil
    }

    private nonisolated static func providerImageFormat(for contentType: UTType) -> String? {
        if contentType.conforms(to: .jpeg) {
            return "jpeg"
        }
        if contentType.conforms(to: .png) {
            return "png"
        }
        if contentType.conforms(to: .gif) {
            return "gif"
        }
        if contentType.conforms(to: .webP) {
            return "webp"
        }
        return nil
    }

    private func providerRequiresAPIKey(_ provider: AIProvider) -> Bool {
        switch provider {
        case .appleIntelligence:
            false
        case .openai, .anthropic:
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
        if let normalizedModel, unrecognizedProviderName(for: normalizedModel) != nil {
            return false
        }
        let activeProvider = normalizedModel.flatMap { modelProviders[$0] } ?? provider
        return requiresAPIKey(for: activeProvider, model: normalizedModel)
    }

    var latestAzureAPIVersion: String {
        azureAPIVersion
    }

    private func isAPIKeyConfigured(for provider: AIProvider, model: String?) -> Bool {
        guard requiresAPIKey(for: provider, model: model) else { return true }

        guard let model,
              let modelKey = modelAPIKeys[model]?.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return false
        }
        return !modelKey.isEmpty
    }

    var isAPIKeyConfigured: Bool {
        let trimmedModel = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = trimmedModel.isEmpty ? nil : trimmedModel
        if let normalizedModel, unrecognizedProviderName(for: normalizedModel) != nil {
            return false
        }
        let activeProvider = normalizedModel.flatMap { modelProviders[$0] } ?? provider
        return isAPIKeyConfigured(for: activeProvider, model: normalizedModel)
    }

    func isModelConfigured(_ model: String) -> Bool {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return isAPIKeyConfigured }
        guard unrecognizedProviderName(for: trimmedModel) == nil else { return false }

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

        if let normalizedModel,
           let providerName = unrecognizedProviderName(for: normalizedModel)
        {
            issues.append("The selected model uses unsupported provider \(providerName)")
            return issues
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
            if unrecognizedProviderName(for: model) != nil {
                return false
            }
            #if os(watchOS)
                if modelProviders[model] == .appleIntelligence {
                    return false
                }
            #endif
            return true
        }

        let testModelName = "ui-test-model"
        if RuntimeEnvironment.isUITesting, !models.contains(testModelName) {
            models.insert(testModelName, at: 0)
        }

        return models
    }

    var textGenerationModels: [String] {
        usableModels.filter { model in
            getModelCapability(model) != .imageGeneration
        }
    }
}

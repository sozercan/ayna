import Foundation

enum OpenAIEndpointResolver {
    struct EndpointConfig {
        let modelName: String
        let provider: AIProvider
        let customEndpoint: String?
        let azureAPIVersion: String

        init(
            modelName: String,
            provider: AIProvider,
            customEndpoint: String? = nil,
            azureAPIVersion: String = "2025-04-01-preview"
        ) {
            self.modelName = modelName
            self.provider = provider
            self.customEndpoint = customEndpoint
            self.azureAPIVersion = azureAPIVersion
        }
    }

    private static let openAIChatURL = "https://api.openai.com/v1/chat/completions"
    private static let openAIResponsesURL = "https://api.openai.com/v1/responses"
    private static let openAIImagesURL = "https://api.openai.com/v1/images/generations"
    private static let openAIImageEditsURL = "https://api.openai.com/v1/images/edits"

    static func chatCompletionsURL(for config: EndpointConfig) throws -> String {
        switch config.provider {
        case .openai:
            try resolveOpenAIChatURL(config)
        case .appleIntelligence:
            ""
        case .anthropic:
            ""
        }
    }

    static func responsesURL(for config: EndpointConfig) throws -> String {
        switch config.provider {
        case .openai:
            try resolveOpenAIResponsesURL(config)
        case .appleIntelligence:
            ""
        case .anthropic:
            ""
        }
    }

    static func imageGenerationURL(for config: EndpointConfig) throws -> String {
        guard config.provider == .openai else {
            return ""
        }

        guard let customEndpoint = config.customEndpoint,
              !customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return openAIImagesURL
        }

        let validatedEndpoint = try validatedCustomEndpoint(customEndpoint)

        if isAzureEndpoint(validatedEndpoint) {
            return azureImagesURL(
                baseEndpoint: validatedEndpoint,
                deployment: config.modelName,
                apiVersion: config.azureAPIVersion
            )
        }

        return appendPathIfNeeded(validatedEndpoint, path: "/v1/images/generations")
    }

    static func imageEditURL(for config: EndpointConfig) throws -> String {
        guard config.provider == .openai else {
            return ""
        }

        guard let customEndpoint = config.customEndpoint,
              !customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return openAIImageEditsURL
        }

        let validatedEndpoint = try validatedCustomEndpoint(customEndpoint)

        if isAzureEndpoint(validatedEndpoint) {
            return azureImageEditsURL(
                baseEndpoint: validatedEndpoint,
                deployment: config.modelName,
                apiVersion: config.azureAPIVersion
            )
        }

        return appendPathIfNeeded(validatedEndpoint, path: "/v1/images/edits")
    }

    static func isAzureEndpoint(_ endpoint: String?) -> Bool {
        guard let endpoint, let url = URL(string: endpoint), let host = url.host?.lowercased() else { return false }
        return host == "openai.azure.com" || host.hasSuffix(".openai.azure.com")
    }

    static func customEndpointRequiresAPIKey(_ endpoint: String?) -> Bool {
        if isAzureEndpoint(endpoint) {
            return true
        }

        guard let endpoint,
              let host = URL(string: endpoint)?.host?.lowercased()
        else {
            return true
        }

        return host == "api.openai.com" || host.hasSuffix(".openai.com")
    }

    private static func resolveOpenAIChatURL(_ config: EndpointConfig) throws -> String {
        guard let customEndpoint = config.customEndpoint,
              !customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return openAIChatURL
        }

        let validatedEndpoint = try validatedCustomEndpoint(customEndpoint)

        if isAzureEndpoint(validatedEndpoint) {
            return azureChatCompletionsURL(
                baseEndpoint: validatedEndpoint,
                deployment: config.modelName,
                apiVersion: config.azureAPIVersion
            )
        }

        return appendPathIfNeeded(validatedEndpoint, path: "/v1/chat/completions")
    }

    private static func resolveOpenAIResponsesURL(_ config: EndpointConfig) throws -> String {
        guard let customEndpoint = config.customEndpoint,
              !customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return openAIResponsesURL
        }

        let validatedEndpoint = try validatedCustomEndpoint(customEndpoint)

        if isAzureEndpoint(validatedEndpoint) {
            return azureResponsesURL(
                baseEndpoint: validatedEndpoint,
                apiVersion: config.azureAPIVersion
            )
        }

        return appendPathIfNeeded(validatedEndpoint, path: "/v1/responses")
    }

    private static func sanitizedBaseEndpoint(_ endpoint: String) -> String {
        endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func validatedCustomEndpoint(_ endpoint: String) throws -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: trimmed), url.host != nil else {
            throw AynaError.invalidEndpoint(trimmed)
        }

        guard let scheme = url.scheme?.lowercased() else {
            throw AynaError.invalidEndpoint(trimmed)
        }

        let isLoopbackHTTP = scheme == "http" && isLoopbackHost(url.host)

        if scheme == "http", !isLoopbackHTTP {
            throw AynaError.invalidEndpoint("HTTP endpoints are not allowed (use HTTPS): \(trimmed)")
        }

        if scheme != "http", scheme != "https" {
            throw AynaError.invalidEndpoint("Invalid URL scheme: \(scheme)")
        }

        return trimmed
    }

    private static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func percentEncodedDeployment(_ deployment: String) -> String {
        deployment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deployment
    }

    private static func azureChatCompletionsURL(
        baseEndpoint: String,
        deployment: String,
        apiVersion: String
    ) -> String {
        let cleanBase = sanitizedBaseEndpoint(baseEndpoint)
        let encodedDeployment = percentEncodedDeployment(deployment)
        return "\(cleanBase)/openai/deployments/\(encodedDeployment)/chat/completions?api-version=\(apiVersion)"
    }

    private static func azureResponsesURL(
        baseEndpoint: String,
        apiVersion: String
    ) -> String {
        let cleanBase = sanitizedBaseEndpoint(baseEndpoint)
        return "\(cleanBase)/openai/responses?api-version=\(apiVersion)"
    }

    private static func azureImagesURL(
        baseEndpoint: String,
        deployment: String,
        apiVersion: String
    ) -> String {
        let cleanBase = sanitizedBaseEndpoint(baseEndpoint)
        let encodedDeployment = percentEncodedDeployment(deployment)
        return "\(cleanBase)/openai/deployments/\(encodedDeployment)/images/generations?api-version=\(apiVersion)"
    }

    private static func azureImageEditsURL(
        baseEndpoint: String,
        deployment: String,
        apiVersion: String
    ) -> String {
        let cleanBase = sanitizedBaseEndpoint(baseEndpoint)
        let encodedDeployment = percentEncodedDeployment(deployment)
        return "\(cleanBase)/openai/deployments/\(encodedDeployment)/images/edits?api-version=\(apiVersion)"
    }

    private static func appendPathIfNeeded(_ endpoint: String, path: String) -> String {
        let cleanBase = sanitizedBaseEndpoint(endpoint)
        if cleanBase.hasSuffix(path) {
            return cleanBase
        }
        for length in stride(from: path.count - 1, through: 1, by: -1) {
            let prefix = String(path.prefix(length))
            if cleanBase.hasSuffix(prefix) {
                return String(cleanBase.dropLast(prefix.count)) + path
            }
        }
        return "\(cleanBase)\(path.hasPrefix("/") ? "" : "/")\(path)"
    }
}

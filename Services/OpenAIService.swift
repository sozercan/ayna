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

    @Published var temperature: Double {
        didSet {
            UserDefaults.standard.set(temperature, forKey: "temperature")
        }
    }

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

    let availableModels = [
        "gpt-4o",
        "gpt-4o-mini",
        "gpt-4-turbo",
        "gpt-4",
        "gpt-3.5-turbo",
        "o1-preview",
        "o1-mini"
    ]

    let azureAPIVersions = [
        "2024-08-01-preview",
        "2024-06-01",
        "2024-05-01-preview",
        "2024-02-01",
        "2023-12-01-preview"
    ]

    init() {
        self.apiKey = UserDefaults.standard.string(forKey: "openai_api_key") ?? ""
        self.selectedModel = UserDefaults.standard.string(forKey: "selectedModel") ?? "gpt-4o"
        self.temperature = UserDefaults.standard.double(forKey: "temperature") != 0 ?
            UserDefaults.standard.double(forKey: "temperature") : 0.7

        if let providerString = UserDefaults.standard.string(forKey: "aiProvider"),
           let savedProvider = AIProvider(rawValue: providerString) {
            self.provider = savedProvider
        } else {
            self.provider = .openai
        }

        self.azureEndpoint = (UserDefaults.standard.string(forKey: "azureEndpoint") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.azureDeploymentName = (UserDefaults.standard.string(forKey: "azureDeploymentName") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.azureAPIVersion = (UserDefaults.standard.string(forKey: "azureAPIVersion") ?? "2024-08-01-preview").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveAPIKey() {
        UserDefaults.standard.set(apiKey, forKey: "openai_api_key")
    }

    private func getAPIURL() -> String {
        switch provider {
        case .openai:
            return openAIURL
        case .azure:
            // Azure OpenAI URL format: https://{endpoint}/openai/deployments/{deployment-name}/chat/completions?api-version={version}
            let cleanEndpoint = azureEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let cleanDeployment = azureDeploymentName.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanVersion = azureAPIVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(cleanEndpoint)/openai/deployments/\(cleanDeployment)/chat/completions?api-version=\(cleanVersion)"
        }
    }

    func sendMessage(
        messages: [Message],
        model: String? = nil,
        temperature: Double? = nil,
        stream: Bool = true,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void
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

        guard let url = URL(string: getAPIURL()) else {
            print("❌ Invalid URL: \(getAPIURL())")
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
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }

        let messagePayloads = messages.map { message in
            [
                "role": message.role.rawValue,
                "content": message.content
            ]
        }

        var body: [String: Any] = [
            "messages": messagePayloads,
            "temperature": requestTemp,
            "stream": stream
        ]

        // OpenAI requires model in body, Azure uses deployment name in URL
        if provider == .openai {
            body["model"] = requestModel
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        if stream {
            streamResponse(request: request, onChunk: onChunk, onComplete: onComplete, onError: onError)
        } else {
            nonStreamResponse(request: request, onChunk: onChunk, onComplete: onComplete, onError: onError)
        }
    }

    private func streamResponse(
        request: URLRequest,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) {
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("❌ Network error: \(error.localizedDescription)")
                    onError(error)
                    return
                }

                if let httpResponse = response as? HTTPURLResponse {
                    print("📡 HTTP Status: \(httpResponse.statusCode)")
                }

                guard let data = data else {
                    print("❌ No data received")
                    onError(OpenAIError.invalidResponse)
                    return
                }

                print("📦 Received \(data.count) bytes")

                let dataString = String(data: data, encoding: .utf8) ?? ""
                let lines = dataString.components(separatedBy: "\n")

                for line in lines {
                    if line.hasPrefix("data: ") {
                        let jsonString = String(line.dropFirst(6))

                        if jsonString.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                            onComplete()
                            return
                        }

                        if let jsonData = jsonString.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                           let choices = json["choices"] as? [[String: Any]],
                           let firstChoice = choices.first,
                           let delta = firstChoice["delta"] as? [String: Any],
                           let content = delta["content"] as? String {
                            onChunk(content)
                        }
                    }
                }

                onComplete()
            }
        }

        task.resume()
    }

    private func nonStreamResponse(
        request: URLRequest,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void
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
                       let message = firstChoice["message"] as? [String: Any],
                       let content = message["content"] as? String {
                        onChunk(content)
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
            }
        }
    }
}

// Keychain Helper


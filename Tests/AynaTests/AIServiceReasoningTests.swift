@testable import Ayna
import Foundation
import Testing

// swiftformat:disable swiftTestingTestCaseNames

extension AIServiceTests {
    @Test("Invalid persisted reasoning entry does not erase valid models")
    func invalidPersistedReasoningEntryDoesNotEraseValidModels() throws {
        let validModel = "gpt-5.6-valid"
        let invalidModel = "gpt-5.6-invalid"
        let validConfiguration = ModelReasoningConfiguration(
            activation: .enabled,
            effort: .high,
            summary: .detailed
        )
        let validData = try JSONEncoder().encode(validConfiguration)
        let validObject = try JSONSerialization.jsonObject(with: validData)
        let persistedObject: [String: Any] = [
            validModel: validObject,
            invalidModel: "not-a-reasoning-configuration"
        ]
        let persistedData = try JSONSerialization.data(withJSONObject: persistedObject)
        AppPreferences.storage.set(
            persistedData,
            forKey: "modelReasoningConfigurations"
        )

        let service = AIService(urlSession: URLSession(configuration: .ephemeral))

        #expect(service.modelReasoningConfigurations[validModel] == validConfiguration)
        #expect(service.modelReasoningConfigurations[invalidModel] == nil)
    }

    @Test("Single-model request prefers an explicit conversation reasoning configuration", .timeLimit(.minutes(1)))
    func singleModelRequestPrefersExplicitConversationReasoning() async throws {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: configuration))
        let model = "gpt-5.6-sol"
        service.customModels = [model]
        service.selectedModel = model
        service.modelProviders[model] = .openai
        service.modelEndpointTypes[model] = .responses
        service.modelAPIKeys[model] = "sk-unit-test"
        service.modelReasoningConfigurations[model] = ModelReasoningConfiguration(
            activation: .disabled
        )
        let conversationConfiguration = ModelReasoningConfiguration(
            activation: .enabled,
            effort: .high,
            summary: .automatic
        )

        let completed = FlightTestSignal()
        service.sendMessage(
            messages: [Message(role: .user, content: "Solve this")],
            model: model,
            stream: false,
            onChunk: { _ in },
            onComplete: { completed.signal() },
            onError: { error in Issue.record("Unexpected error: \(error)") },
            reasoningConfiguration: conversationConfiguration
        )

        let exchange = await server.exchange(at: 0)
        let body = try requestBody(from: exchange.request)
        let reasoning = try #require(body["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "high")
        #expect(reasoning["summary"] as? String == "auto")

        exchange.sendResponse(statusCode: 200, headers: ["Content-Type": "application/json"])
        exchange.send(Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"done"}]}]}"#.utf8))
        exchange.finish()
        #expect(await completed.wait(timeout: .seconds(1)))
    }

    @Test("Multi-model requests freeze reasoning settings at dispatch", .timeLimit(.minutes(1)))
    func multiModelRequestsFreezeReasoningSettingsAtDispatch() async throws {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: configuration))
        let model = "gpt-5.6-sol"
        service.customModels = [model]
        service.selectedModel = model
        service.modelProviders[model] = .openai
        service.modelEndpointTypes[model] = .responses
        service.modelAPIKeys[model] = "sk-unit-test"

        var initialReasoning = ModelReasoningConfiguration.automatic
        initialReasoning.effort = .high
        initialReasoning.summary = .automatic
        service.modelReasoningConfigurations[model] = initialReasoning

        let completed = FlightTestSignal()
        service.sendToMultipleModels(
            messages: [Message(role: .user, content: "Solve this")],
            models: [model],
            onChunk: { _, _ in },
            onModelComplete: { _ in },
            onAllComplete: { completed.signal() },
            onError: { _, error in Issue.record("Unexpected error: \(error)") }
        )

        var replacementReasoning = ModelReasoningConfiguration.automatic
        replacementReasoning.activation = .disabled
        service.modelReasoningConfigurations[model] = replacementReasoning

        let exchange = await server.exchange(at: 0)
        let body = try requestBody(from: exchange.request)
        let reasoning = try #require(body["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "high")
        #expect(reasoning["summary"] as? String == "auto")

        exchange.sendResponse(statusCode: 200, headers: ["Content-Type": "application/json"])
        exchange.send(Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"done"}]}]}"#.utf8))
        exchange.finish()
        #expect(await completed.wait(timeout: .seconds(1)))
    }

    @Test("Multi-model requests freeze an explicit conversation override", .timeLimit(.minutes(1)))
    func multiModelRequestsFreezeExplicitConversationOverride() async throws {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: configuration))
        let model = "gpt-5.6-sol"
        service.customModels = [model]
        service.selectedModel = model
        service.modelProviders[model] = .openai
        service.modelEndpointTypes[model] = .responses
        service.modelAPIKeys[model] = "sk-unit-test"
        service.modelReasoningConfigurations[model] = ModelReasoningConfiguration(
            activation: .disabled
        )
        let conversationConfiguration = ModelReasoningConfiguration(
            activation: .enabled,
            effort: .medium,
            summary: .automatic
        )

        let completed = FlightTestSignal()
        service.sendToMultipleModels(
            messages: [Message(role: .user, content: "Compare this")],
            models: [model],
            onChunk: { _, _ in },
            onModelComplete: { _ in },
            onAllComplete: { completed.signal() },
            onError: { _, error in Issue.record("Unexpected error: \(error)") },
            reasoningConfiguration: conversationConfiguration
        )

        service.modelReasoningConfigurations[model] = ModelReasoningConfiguration(
            activation: .enabled,
            effort: .max
        )

        let exchange = await server.exchange(at: 0)
        let body = try requestBody(from: exchange.request)
        let reasoning = try #require(body["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "medium")
        #expect(reasoning["summary"] as? String == "auto")

        exchange.sendResponse(statusCode: 200, headers: ["Content-Type": "application/json"])
        exchange.send(Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"done"}]}]}"#.utf8))
        exchange.finish()
        #expect(await completed.wait(timeout: .seconds(1)))
    }

    @Test("Tool continuation reuses opaque state and request settings for the same model", .timeLimit(.minutes(1)))
    func toolContinuationReusesStateForSameModel() async throws {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: configuration))
        let model = "gpt-5.6-tool-continuation"
        service.customModels = [model]
        service.selectedModel = model
        service.modelProviders[model] = .openai
        service.modelEndpointTypes[model] = .responses
        service.modelAPIKeys[model] = "sk-unit-test"

        var disabledReasoning = ModelReasoningConfiguration.automatic
        disabledReasoning.activation = .disabled
        service.modelReasoningConfigurations[model] = disabledReasoning

        let continuedConfiguration = ResolvedReasoningConfiguration(
            dialect: .openAIResponses,
            effort: .high,
            openAIMode: nil,
            openAIContext: .currentTurn,
            summary: .automatic,
            anthropicDisplay: .summarized,
            legacyBudgetTokens: 4096
        )
        let messages = toolContinuationMessages(
            assistantModel: model,
            continuationModel: model,
            requestConfiguration: continuedConfiguration
        )

        let completed = FlightTestSignal()
        service.sendMessage(
            messages: messages,
            model: model,
            stream: false,
            onChunk: { _ in },
            onComplete: { completed.signal() },
            onError: { error in Issue.record("Unexpected error: \(error)") }
        )

        let exchange = await server.exchange(at: 0)
        let body = try requestBody(from: exchange.request)
        let reasoning = try #require(body["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "high")
        #expect(reasoning["summary"] as? String == "auto")
        #expect(reasoning["context"] as? String == "current_turn")

        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.map { $0["type"] as? String } == [
            "reasoning", "function_call", "function_call_output"
        ])
        #expect(input[0]["encrypted_content"] as? String == "opaque-token")

        exchange.sendResponse(statusCode: 200, headers: ["Content-Type": "application/json"])
        exchange.send(Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"done"}]}]}"#.utf8))
        exchange.finish()
        #expect(await completed.wait(timeout: .seconds(1)))
    }

    @Test("Tool continuation does not cross model boundaries", .timeLimit(.minutes(1)))
    func toolContinuationDoesNotCrossModelBoundaries() async throws {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: configuration))
        let oldModel = "gpt-5.6-old"
        let newModel = "gpt-5.6-new"
        service.customModels = [newModel]
        service.selectedModel = newModel
        service.modelProviders[newModel] = .openai
        service.modelEndpointTypes[newModel] = .responses
        service.modelAPIKeys[newModel] = "sk-unit-test"

        var disabledReasoning = ModelReasoningConfiguration.automatic
        disabledReasoning.activation = .disabled
        service.modelReasoningConfigurations[newModel] = disabledReasoning

        let oldConfiguration = ResolvedReasoningConfiguration(
            dialect: .openAIResponses,
            effort: .high,
            openAIMode: nil,
            openAIContext: .currentTurn,
            summary: .automatic,
            anthropicDisplay: .summarized,
            legacyBudgetTokens: 4096
        )
        let messages = toolContinuationMessages(
            assistantModel: oldModel,
            continuationModel: oldModel,
            requestConfiguration: oldConfiguration
        )

        let completed = FlightTestSignal()
        service.sendMessage(
            messages: messages,
            model: newModel,
            stream: false,
            onChunk: { _ in },
            onComplete: { completed.signal() },
            onError: { error in Issue.record("Unexpected error: \(error)") }
        )

        let exchange = await server.exchange(at: 0)
        let body = try requestBody(from: exchange.request)
        #expect(body["reasoning"] == nil)

        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.map { $0["type"] as? String } == ["function_call", "function_call_output"])
        #expect(!input.contains { $0["encrypted_content"] != nil })

        exchange.sendResponse(statusCode: 200, headers: ["Content-Type": "application/json"])
        exchange.send(Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"done"}]}]}"#.utf8))
        exchange.finish()
        #expect(await completed.wait(timeout: .seconds(1)))
    }

    @Test("Tool continuation preserves a captured provider-default request", .timeLimit(.minutes(1)))
    func toolContinuationPreservesProviderDefault() async throws {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: configuration))
        let model = "provider-default-tool-continuation"
        service.customModels = [model]
        service.selectedModel = model
        service.modelProviders[model] = .openai
        service.modelEndpointTypes[model] = .responses
        service.modelAPIKeys[model] = "sk-unit-test"

        var newlyEnabledReasoning = ModelReasoningConfiguration.automatic
        newlyEnabledReasoning.activation = .enabled
        newlyEnabledReasoning.effort = .high
        newlyEnabledReasoning.summary = .automatic
        service.modelReasoningConfigurations[model] = newlyEnabledReasoning

        let messages = toolContinuationMessages(
            assistantModel: model,
            continuationModel: model,
            requestConfiguration: nil
        )

        let completed = FlightTestSignal()
        service.sendMessage(
            messages: messages,
            model: model,
            stream: false,
            onChunk: { _ in },
            onComplete: { completed.signal() },
            onError: { error in Issue.record("Unexpected error: \(error)") }
        )

        let exchange = await server.exchange(at: 0)
        let body = try requestBody(from: exchange.request)
        #expect(body["reasoning"] == nil)

        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.map { $0["type"] as? String } == [
            "reasoning", "function_call", "function_call_output"
        ])
        #expect(input[0]["encrypted_content"] as? String == "opaque-token")

        exchange.sendResponse(statusCode: 200, headers: ["Content-Type": "application/json"])
        exchange.send(Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"done"}]}]}"#.utf8))
        exchange.finish()
        #expect(await completed.wait(timeout: .seconds(1)))
    }

    @Test("Chat Completions tool continuations freeze explicit conversation reasoning", .timeLimit(.minutes(1)))
    func chatCompletionsToolContinuationFreezesExplicitConversationReasoning() async throws {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: configuration))
        let model = "custom-chat-tool-reasoning"
        configureOpenAIChatService(service, model: model)

        var initialReasoning = ModelReasoningConfiguration.automatic
        initialReasoning.activation = .enabled
        initialReasoning.effort = .high
        service.modelReasoningConfigurations[model] = ModelReasoningConfiguration(
            activation: .disabled
        )

        let messages = try await registerOpenAIChatToolRequest(
            service: service,
            server: server,
            model: model,
            toolCallID: "chat-freeze-call",
            reasoningConfiguration: initialReasoning
        )

        let changedConversationConfiguration = ModelReasoningConfiguration(
            activation: .disabled
        )

        let completed = FlightTestSignal()
        service.sendMessage(
            messages: messages,
            model: model,
            stream: false,
            onChunk: { _ in },
            onComplete: { completed.signal() },
            onError: { error in Issue.record("Unexpected error: \(error)") },
            reasoningConfiguration: changedConversationConfiguration
        )

        let continuation = await server.exchange(at: 1)
        let body = try requestBody(from: continuation.request)
        #expect(body["reasoning_effort"] as? String == "high")
        continuation.sendResponse(statusCode: 200, headers: ["Content-Type": "application/json"])
        continuation.send(Data(#"{"choices":[{"message":{"content":"done"}}]}"#.utf8))
        continuation.finish()
        #expect(await completed.wait(timeout: .seconds(1)))
    }

    @Test("Anthropic tool-only continuations freeze settings without thinking blocks", .timeLimit(.minutes(1)))
    func anthropicToolOnlyContinuationFreezesReasoningSettings() async throws {
        let factory = ReasoningTestAnthropicProviderFactory()
        let service = AIService(anthropicProviderFactory: { _ in factory.makeProvider() })
        let model = "claude-tool-only-reasoning"
        service.customModels = [model]
        service.selectedModel = model
        service.modelProviders[model] = .anthropic
        service.modelAPIKeys[model] = "sk-ant-unit-test"

        var initialReasoning = ModelReasoningConfiguration.automatic
        initialReasoning.activation = .enabled
        initialReasoning.effort = .high
        service.modelReasoningConfigurations[model] = initialReasoning

        let toolRequested = FlightTestSignal()
        service.sendMessage(
            messages: [Message(role: .user, content: "Use a tool")],
            model: model,
            onChunk: { _ in },
            onComplete: {},
            onError: { error in Issue.record("Unexpected error: \(error)") },
            onToolCallRequested: { _, _, _ in toolRequested.signal() }
        )
        let firstProvider = try #require(factory.providers.first)
        firstProvider.emitToolRequest(id: "anthropic-tool-only-call", name: "web_search")
        #expect(await toolRequested.wait(timeout: .seconds(1)))

        service.modelReasoningConfigurations[model] = ModelReasoningConfiguration(
            activation: .disabled
        )
        let completed = FlightTestSignal()
        service.sendMessage(
            messages: toolResultMessages(model: model, toolCallID: "anthropic-tool-only-call"),
            model: model,
            onChunk: { _ in },
            onComplete: { completed.signal() },
            onError: { error in Issue.record("Unexpected error: \(error)") }
        )

        let continuationProvider = try #require(factory.providers.last)
        guard case let .adaptive(effort, _) = continuationProvider.config?.anthropicReasoning else {
            Issue.record("Expected the originating adaptive reasoning configuration")
            return
        }
        #expect(effort == .high)
        continuationProvider.complete()
        #expect(await completed.wait(timeout: .seconds(1)))
    }

    @Test("Tool continuations reject provider and endpoint changes", .timeLimit(.minutes(1)))
    func toolContinuationsRejectProviderAndEndpointChanges() async throws {
        for mutation in ToolConfigurationMutation.allCases {
            let server = FlightTestURLProtocolServer()
            FlightTestURLProtocol.install(server: server)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FlightTestURLProtocol.self]
            let service = AIService(urlSession: URLSession(configuration: configuration))
            let model = "tool-drift-\(mutation.rawValue)"
            configureOpenAIChatService(service, model: model)

            var initialReasoning = ModelReasoningConfiguration.automatic
            initialReasoning.activation = .enabled
            initialReasoning.effort = .high
            service.modelReasoningConfigurations[model] = initialReasoning
            let messages = try await registerOpenAIChatToolRequest(
                service: service,
                server: server,
                model: model,
                toolCallID: "drift-\(mutation.rawValue)"
            )

            switch mutation {
            case .provider:
                service.modelProviders[model] = .anthropic
            case .endpoint:
                service.modelEndpointTypes[model] = .responses
            }

            let errorBox = FlightTestBox<String?>(nil)
            let failed = FlightTestSignal()
            service.sendMessage(
                messages: messages,
                model: model,
                stream: false,
                onChunk: { _ in },
                onComplete: { Issue.record("Drifted continuation must not complete") },
                onError: {
                    errorBox.value = $0.localizedDescription
                    failed.signal()
                }
            )

            #expect(await failed.wait(timeout: .seconds(1)))
            #expect(errorBox.value?.contains("provider or endpoint type changed") == true)
            #expect(await !(server.waitForRequestCount(2, timeout: .milliseconds(50))))
        }
    }

    private enum ToolConfigurationMutation: String, CaseIterable {
        case provider
        case endpoint
    }

    private func configureOpenAIChatService(_ service: AIService, model: String) {
        service.customModels = [model]
        service.selectedModel = model
        service.modelProviders[model] = .openai
        service.modelEndpointTypes[model] = .chatCompletions
        service.modelAPIKeys[model] = "sk-unit-test"
    }

    private func registerOpenAIChatToolRequest(
        service: AIService,
        server: FlightTestURLProtocolServer,
        model: String,
        toolCallID: String,
        reasoningConfiguration: ModelReasoningConfiguration? = nil
    ) async throws -> [Message] {
        let toolRequested = FlightTestSignal()
        service.sendMessage(
            messages: [Message(role: .user, content: "Use a tool")],
            model: model,
            onChunk: { _ in },
            onComplete: {},
            onError: { error in Issue.record("Unexpected error: \(error)") },
            onToolCallRequested: { id, _, _ in
                #expect(id == toolCallID)
                toolRequested.signal()
            },
            reasoningConfiguration: reasoningConfiguration
        )

        let exchange = await server.exchange(at: 0)
        let body = try requestBody(from: exchange.request)
        #expect(body["reasoning_effort"] as? String == "high")
        exchange.sendResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"])
        exchange.send(Data(
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"\#(toolCallID)","function":{"name":"web_search","arguments":"{}"}}]}}]}"#.utf8
        ))
        exchange.send(Data("\n".utf8))
        exchange.send(Data(#"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#.utf8))
        exchange.send(Data("\n".utf8))
        #expect(await toolRequested.wait(timeout: .seconds(1)))
        exchange.send(Data("data: [DONE]\n".utf8))
        exchange.finish()
        return toolResultMessages(model: model, toolCallID: toolCallID)
    }

    private func toolResultMessages(model: String, toolCallID: String) -> [Message] {
        let toolCall = MCPToolCall(
            id: toolCallID,
            toolName: "web_search",
            arguments: [:]
        )
        var assistant = Message(role: .assistant, content: "", model: model)
        assistant.toolCalls = [toolCall]
        var result = Message(role: .tool, content: "Sunny")
        result.toolCalls = [
            MCPToolCall(
                id: toolCallID,
                toolName: toolCall.toolName,
                arguments: toolCall.arguments,
                result: "Sunny"
            )
        ]
        return [assistant, result]
    }

    private func requestBody(from request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }

            var streamedData = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: bufferSize)
                guard count > 0 else { break }
                streamedData.append(buffer, count: count)
            }
            data = streamedData
        }

        let bodyData = try #require(data)
        return try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    }

    private func toolContinuationMessages(
        assistantModel: String,
        continuationModel: String,
        requestConfiguration: ResolvedReasoningConfiguration?
    ) -> [Message] {
        let toolCall = MCPToolCall(
            id: "call-1",
            toolName: "web_search",
            arguments: ["query": AnyCodable("weather")]
        )
        var assistant = Message(role: .assistant, content: "", model: assistantModel)
        assistant.toolCalls = [toolCall]
        assistant.reasoningContinuation = ReasoningContinuationState(
            format: .openAIResponses,
            items: [
                AnyCodable([
                    "type": "reasoning",
                    "id": "reasoning-1",
                    "encrypted_content": "opaque-token"
                ]),
                AnyCodable([
                    "type": "function_call",
                    "id": "function-call-1",
                    "call_id": toolCall.id,
                    "name": toolCall.toolName,
                    "arguments": "{\"query\":\"weather\"}"
                ])
            ]
        ).attaching(
            model: continuationModel,
            requestConfiguration: requestConfiguration
        )

        var result = Message(role: .tool, content: "Sunny")
        result.toolCalls = [
            MCPToolCall(
                id: toolCall.id,
                toolName: toolCall.toolName,
                arguments: toolCall.arguments,
                result: "Sunny"
            )
        ]
        return [assistant, result]
    }
}

@MainActor
private final class ReasoningTestAnthropicProvider: AIProviderProtocol, @unchecked Sendable {
    let providerType: AIProvider = .anthropic
    let requiresAPIKey = true
    private(set) var config: AIProviderRequestConfig?
    private var callbacks: AIProviderStreamCallbacks?

    func sendMessage(
        messages _: [Message],
        config: AIProviderRequestConfig,
        stream _: Bool,
        tools _: [[String: Any]]?,
        callbacks: AIProviderStreamCallbacks
    ) {
        self.config = config
        self.callbacks = callbacks
    }

    func cancelRequest() {}

    func emitToolRequest(id: String, name: String) {
        callbacks?.onToolCallRequested?(id, name, [:])
    }

    func complete() {
        callbacks?.onComplete()
    }
}

@MainActor
private final class ReasoningTestAnthropicProviderFactory {
    private(set) var providers: [ReasoningTestAnthropicProvider] = []

    func makeProvider() -> ReasoningTestAnthropicProvider {
        let provider = ReasoningTestAnthropicProvider()
        providers.append(provider)
        return provider
    }
}

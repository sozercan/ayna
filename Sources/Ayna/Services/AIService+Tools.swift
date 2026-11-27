import Foundation

extension AIService {
    func getAgenticSystemPromptContext() -> String? {
        var contexts: [String] = []

        if let webFetchContext = webFetchService.systemPromptContext() {
            contexts.append(webFetchContext)
        }

        #if os(macOS)
            if let builtinContext = builtinToolService?.systemPromptContext() {
                contexts.append(builtinContext)
            }
        #endif

        return contexts.isEmpty ? nil : contexts.joined(separator: "\n\n")
    }

    func getAllAvailableTools() -> [[String: Any]]? {
        var tools: [[String: Any]] = []

        #if os(watchOS)
            if webSearchEnabled {
                tools.append(WebSearchCoordinator.shared.toolDefinition())
                DiagnosticsLogger.log(
                    .aiService,
                    level: .info,
                    message: "🔧 Added web_search tool (watchOS)"
                )
            }
        #else
            if WebSearchCoordinator.shared.isAvailable {
                tools.append(WebSearchCoordinator.shared.toolDefinition())
                DiagnosticsLogger.log(
                    .aiService,
                    level: .info,
                    message: "🔧 Added web_search tool (\(WebSearchCoordinator.shared.activeProvider))"
                )
            }
        #endif

        if webFetchService.isEnabled {
            tools.append(webFetchService.toolDefinition())
            DiagnosticsLogger.log(
                .aiService,
                level: .info,
                message: "🔧 Added web_fetch tool"
            )
        }

        #if os(macOS)
            if let builtinService = builtinToolService {
                let builtinTools = builtinService.allToolDefinitions()
                tools.append(contentsOf: builtinTools)
                DiagnosticsLogger.log(
                    .aiService,
                    level: .info,
                    message: "🔧 Added builtin tools",
                    metadata: [
                        "count": "\(builtinTools.count)",
                        "isEnabled": "\(builtinService.isEnabled)"
                    ]
                )
            } else {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .info,
                    message: "⚠️ builtinToolService is nil"
                )
            }
        #endif

        #if os(macOS)
            let mcpTools = MCPServerManager.shared.getEnabledToolsAsOpenAIFunctions()
            tools.append(contentsOf: mcpTools)
            if !mcpTools.isEmpty {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .info,
                    message: "🔧 Added MCP tools",
                    metadata: ["count": "\(mcpTools.count)"]
                )
            }
        #endif

        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: "🔧 getAllAvailableTools returning",
            metadata: ["totalTools": "\(tools.count)", "isNil": "\(tools.isEmpty)"]
        )

        return tools.isEmpty ? nil : tools
    }

    func isBuiltInTool(_ toolName: String) -> Bool {
        #if os(watchOS)
            toolName == WebSearchCoordinator.toolName || WebFetchService.isWebFetchTool(toolName)
        #elseif os(macOS)
            toolName == WebSearchCoordinator.toolName || BuiltinToolService.isBuiltinTool(toolName) || WebFetchService.isWebFetchTool(toolName)
        #else
            toolName == WebSearchCoordinator.toolName || WebFetchService.isWebFetchTool(toolName)
        #endif
    }

    func executeBuiltInTool(name toolName: String, arguments: [String: Any], conversationId: UUID? = nil) async -> String {
        if WebFetchService.isWebFetchTool(toolName) {
            return await webFetchService.executeToolCall(
                arguments: arguments,
                conversationId: conversationId
            )
        }

        #if os(watchOS)
            switch toolName {
            case WebSearchCoordinator.toolName:
                return await WebSearchCoordinator.shared.executeToolCall(arguments: arguments)
            default:
                return "Error: Unknown built-in tool '\(toolName)'"
            }
        #elseif os(macOS)
            if BuiltinToolService.isBuiltinTool(toolName) {
                guard let service = builtinToolService else {
                    return "Error: Agentic tools not configured"
                }
                guard let convId = conversationId else {
                    return "Error: Conversation ID required for agentic tools"
                }
                return await service.executeToolCall(
                    toolName: toolName,
                    arguments: arguments,
                    conversationId: convId
                )
            }

            switch toolName {
            case WebSearchCoordinator.toolName:
                return await WebSearchCoordinator.shared.executeToolCall(arguments: arguments)
            default:
                return "Error: Unknown built-in tool '\(toolName)'"
            }
        #else
            switch toolName {
            case WebSearchCoordinator.toolName:
                return await WebSearchCoordinator.shared.executeToolCall(arguments: arguments)
            default:
                return "Error: Unknown built-in tool '\(toolName)'"
            }
        #endif
    }

    func executeBuiltInToolWithCitations(
        name toolName: String,
        arguments: [String: Any],
        conversationId: UUID? = nil
    ) async -> (String, [CitationReference]?) {
        if WebFetchService.isWebFetchTool(toolName) {
            let result = await webFetchService.executeToolCall(
                arguments: arguments,
                conversationId: conversationId
            )
            return (result, nil)
        }

        #if os(watchOS)
            switch toolName {
            case WebSearchCoordinator.toolName:
                let (result, citations) = await WebSearchCoordinator.shared.executeToolCallWithCitations(arguments: arguments)
                return (result, citations.isEmpty ? nil : citations)
            default:
                let result = await executeBuiltInTool(name: toolName, arguments: arguments)
                return (result, nil)
            }
        #elseif os(macOS)
            if BuiltinToolService.isBuiltinTool(toolName) {
                let result = await executeBuiltInTool(name: toolName, arguments: arguments, conversationId: conversationId)
                return (result, nil)
            }

            switch toolName {
            case WebSearchCoordinator.toolName:
                let (result, citations) = await WebSearchCoordinator.shared.executeToolCallWithCitations(arguments: arguments)
                return (result, citations.isEmpty ? nil : citations)
            default:
                return ("Error: Unknown built-in tool '\(toolName)'", nil)
            }
        #else
            switch toolName {
            case WebSearchCoordinator.toolName:
                let (result, citations) = await WebSearchCoordinator.shared.executeToolCallWithCitations(arguments: arguments)
                return (result, citations.isEmpty ? nil : citations)
            default:
                return ("Error: Unknown built-in tool '\(toolName)'", nil)
            }
        #endif
    }
}

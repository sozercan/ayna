//
//  AppleIntelligenceTools.swift
//  ayna
//
//  Created on 11/12/25.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Tool Wrapper for MCP Tools

/// Generic wrapper for MCP tools with flexible string-based arguments
/// This is a workaround since Apple's Tool protocol requires compile-time Arguments type
@available(macOS 26.0, iOS 26.0, *)
struct GenericMCPTool: Tool, Sendable {
    let toolName: String
    let toolDescription: String

    var name: String { toolName }
    var description: String { toolDescription }

    // Accept arbitrary JSON as a string since we can't define dynamic Arguments at compile time
    @Generable
    struct Arguments: Sendable {
        @Guide(description: "JSON string containing the tool arguments")
        let arguments: String

        init(arguments: String = "{}") {
            self.arguments = arguments
        }
    }

    typealias Output = String

    func call(arguments: Arguments) async throws -> String {
        print("🛠️ [Apple Intelligence] Calling tool: \(toolName)")
        print("📋 Arguments: \(arguments.arguments)")

        // Parse the JSON string
        guard let data = arguments.arguments.data(using: .utf8),
              let params = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("❌ Failed to parse arguments as JSON")
            throw ToolError.invalidArguments("Failed to parse JSON arguments: \(arguments.arguments)")
        }

        // Execute via MCP manager
        do {
            let result = try await MCPServerManager.shared.executeTool(
                name: toolName,
                arguments: params
            )
            print("✅ [Apple Intelligence] Tool \(toolName) completed successfully")
            return result
        } catch {
            print("❌ [Apple Intelligence] Tool \(toolName) failed: \(error.localizedDescription)")
            throw ToolError.executionFailed(error.localizedDescription)
        }
    }
}

// MARK: - Tool Errors

enum ToolError: LocalizedError {
    case invalidArguments(String)
    case executionFailed(String)
    case toolNotAvailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let reason):
            return "Invalid tool arguments: \(reason)"
        case .executionFailed(let reason):
            return "Tool execution failed: \(reason)"
        case .toolNotAvailable(let name):
            return "Tool '\(name)' is not available"
        }
    }
}

// MARK: - Tool Registry

/// Manages the registration and lifecycle of Apple Intelligence tools
@available(macOS 26.0, iOS 26.0, *)
class AppleIntelligenceToolRegistry: ObservableObject {
    static let shared = AppleIntelligenceToolRegistry()

    @Published var enabledForAppleIntelligence: Bool {
        didSet {
            UserDefaults.standard.set(enabledForAppleIntelligence, forKey: "appleIntelligence_toolsEnabled")
            // Clear all sessions when tools are toggled so new sessions pick up the change
            if #available(macOS 26.0, iOS 26.0, *) {
                AppleIntelligenceService.shared.clearAllSessions()
                print("🔄 Cleared Apple Intelligence sessions due to tool setting change")
            }
        }
    }

    @Published var maxToolCount: Int {
        didSet {
            UserDefaults.standard.set(maxToolCount, forKey: "appleIntelligence_maxToolCount")
        }
    }

    private init() {
        self.enabledForAppleIntelligence = UserDefaults.standard.bool(forKey: "appleIntelligence_toolsEnabled")
        let savedMaxCount = UserDefaults.standard.integer(forKey: "appleIntelligence_maxToolCount")
        self.maxToolCount = savedMaxCount > 0 ? savedMaxCount : 5
    }

    /// Get all available tools wrapped for Apple Intelligence
    func getAvailableTools() -> [GenericMCPTool] {
        guard enabledForAppleIntelligence else {
            print("ℹ️ Tools disabled for Apple Intelligence")
            return []
        }

        let mcpTools = MCPServerManager.shared.getEnabledTools()
        print("📦 Found \(mcpTools.count) enabled MCP tools")

        // Limit tools to prevent context window overflow
        let limitedTools = Array(mcpTools.prefix(maxToolCount))

        if mcpTools.count > maxToolCount {
            print("⚠️ Limited tools from \(mcpTools.count) to \(maxToolCount) for context window")
        }

        let wrappers = limitedTools.map { tool in
            GenericMCPTool(
                toolName: tool.name,
                toolDescription: tool.description
            )
        }
        print("🔧 Registered \(wrappers.count) tools for Apple Intelligence: \(wrappers.map { $0.name })")

        return wrappers
    }

    /// Check if tools are available and properly configured
    func validateToolAvailability() -> (available: Bool, message: String) {
        guard enabledForAppleIntelligence else {
            return (false, "Tools are disabled for Apple Intelligence")
        }

        let mcpTools = MCPServerManager.shared.getEnabledTools()
        guard !mcpTools.isEmpty else {
            return (false, "No MCP tools available. Enable MCP servers in settings.")
        }

        let connectedServers = MCPServerManager.shared.getConnectedServerCount()
        guard connectedServers > 0 else {
            return (false, "No MCP servers connected. Check server configuration.")
        }

        return (true, "\(mcpTools.count) tools available from \(connectedServers) server(s)")
    }
}

// MARK: - Compatibility Layer

/// Provides access to tool registry with backwards compatibility
/// Returns nil on older OS versions to prevent crashes
class AppleIntelligenceToolsCompat {
    static var shared: AnyObject? {
        if #available(macOS 26.0, iOS 26.0, *) {
            return AppleIntelligenceToolRegistry.shared
        }
        return nil
    }

    static func isAvailable() -> Bool {
        if #available(macOS 26.0, iOS 26.0, *) {
            return true
        }
        return false
    }
}

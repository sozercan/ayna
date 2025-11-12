//
//  AppleIntelligenceService.swift
//  ayna
//
//  Created on 11/6/25.
//

import Foundation
import FoundationModels

enum AppleIntelligenceError: LocalizedError {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unavailable(String)
    case sessionCreationFailed
    case generationFailed(String)
  case tooManyToolCalls

    var errorDescription: String? {
        switch self {
        case .deviceNotEligible:
            return "This device is not eligible for Apple Intelligence"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is not enabled in System Settings"
        case .modelNotReady:
            return "Apple Intelligence model assets are not downloaded yet"
        case .unavailable(let reason):
            return "Apple Intelligence is unavailable: \(reason)"
        case .sessionCreationFailed:
            return "Failed to create Apple Intelligence session"
        case .generationFailed(let error):
            return "Response generation failed: \(error)"
    case .tooManyToolCalls:
      return "Too many tool calls in sequence. Stopping to prevent infinite loop."
        }
    }
}

// MARK: - Tool Call Parsing

struct ParsedToolCall {
  let toolName: String
  let arguments: [String: Any]
  let rawResponse: String
}

@available(macOS 26.0, iOS 26.0, *)
class AppleIntelligenceService: ObservableObject {
    static let shared = AppleIntelligenceService()

    @Published var model = SystemLanguageModel.default
    private var sessions: [String: LanguageModelSession] = [:]
  private let sessionsLock = NSLock()
  private let maxToolCallDepth = 5  // Prevent infinite loops

  private init() {}

    // Check if Apple Intelligence is available on this device
    var isAvailable: Bool {
        return model.isAvailable
    }

    var availability: SystemLanguageModel.Availability {
        return model.availability
    }

    func availabilityDescription() -> String {
        switch availability {
        case .available:
            return "Available"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "Device not eligible for Apple Intelligence"
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence not enabled in System Settings"
            case .modelNotReady:
                return "Model assets not downloaded yet"
            @unknown default:
                return "Unknown availability issue"
            }
        @unknown default:
            return "Unknown availability status"
        }
    }

    // Get or create a session for a conversation
    private func getSession(
        conversationId: String,
        systemInstructions: String
    ) -> LanguageModelSession {
    sessionsLock.lock()
    defer { sessionsLock.unlock() }

    if let existingSession = sessions[conversationId] {
            return existingSession
        }

    // WORKAROUND: Apple's Tool protocol doesn't support runtime-discovered tools
    // For now, create session WITHOUT native tool support
    // We'll implement manual tool calling via system instructions instead

    let enhancedInstructions: String

    // Debug: Check tool availability
    let toolsCompatAvailable = AppleIntelligenceToolsCompat.isAvailable()
    print("🔍 [Debug] AppleIntelligenceToolsCompat.isAvailable: \(toolsCompatAvailable)")

    if toolsCompatAvailable,
      let registry = AppleIntelligenceToolsCompat.shared as? AppleIntelligenceToolRegistry
    {
      print(
        "🔍 [Debug] Registry found, enabledForAppleIntelligence: \(registry.enabledForAppleIntelligence)"
      )

      if registry.enabledForAppleIntelligence {
        let mcpTools = MCPServerManager.shared.getEnabledTools()
        print("🔍 [Debug] Enabled MCP tools count: \(mcpTools.count)")

        if !mcpTools.isEmpty {
          print(
            "🔧 Creating session with manual tool calling support (\(mcpTools.count) tools available)"
          )
          // Add tool descriptions to system instructions
          let toolDescriptions = mcpTools.prefix(5).map { tool in
            "- \(tool.name): \(tool.description)"
          }.joined(separator: "\n")

          enhancedInstructions = """
            \(systemInstructions)

            CRITICAL INSTRUCTIONS - TOOL USAGE:

            You are equipped with powerful tools. Use them when needed.

            To use a tool, respond EXACTLY in this format:
            TOOL_CALL: <tool_name>
            ARGUMENTS: <json_arguments>

            Available tools:
            \(toolDescriptions)

            IMPORTANT RULES:
            - Call ONLY ONE tool per response
            - After receiving tool result, answer the user - DO NOT call another tool
            - DO NOT use component/policy/permission/time tools
            - For file listing: use list_directory with {"path": "/Users/sozercan"}
            - For reading files: use read_file with {"path": "file_path"}
            """
          print("📋 Enhanced instructions with \(mcpTools.prefix(5).count) tool descriptions")
        } else {
          print("⚠️ Tools enabled but no MCP tools available (check MCP server connections)")
          enhancedInstructions = systemInstructions
        }
      } else {
        print(
          "ℹ️ Tools disabled in settings (Settings → Models → Apple Intelligence → Enable MCP Tools)"
        )
        enhancedInstructions = systemInstructions
      }
    } else {
      print("⚠️ Tool compat not available or registry not accessible")
      enhancedInstructions = systemInstructions
    }

    let newSession = LanguageModelSession(instructions: enhancedInstructions)
        sessions[conversationId] = newSession
        return newSession
    }

    // Clear session for a conversation
    func clearSession(conversationId: String) {
    sessionsLock.lock()
    defer { sessionsLock.unlock() }
        sessions.removeValue(forKey: conversationId)
    }

    // Clear all sessions
    func clearAllSessions() {
    sessionsLock.lock()
    defer { sessionsLock.unlock() }
    sessions.removeAll()
  }

  // Get tool availability status
  func getToolStatus() -> (enabled: Bool, available: Bool, message: String) {
    guard AppleIntelligenceToolsCompat.isAvailable() else {
      return (false, false, "Tool calling requires macOS 26.0+")
    }

    guard let registry = AppleIntelligenceToolsCompat.shared as? AppleIntelligenceToolRegistry
    else {
      return (false, false, "Tool registry unavailable")
    }

    let validation = registry.validateToolAvailability()
    return (registry.enabledForAppleIntelligence, validation.available, validation.message)
  }

  // MARK: - Tool Call Parsing

  /// Parse tool call from model response
  /// Expected format:
  /// TOOL_CALL: tool_name
  /// ARGUMENTS: {"key": "value"}
  private func parseToolCall(from response: String) -> ParsedToolCall? {
    let lines = response.components(separatedBy: .newlines)

    var toolName: String?
    var argumentsJSON: String?

    for (index, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if trimmed.hasPrefix("TOOL_CALL:") {
        toolName =
          trimmed
          .replacingOccurrences(of: "TOOL_CALL:", with: "")
          .trimmingCharacters(in: .whitespaces)
      } else if trimmed.hasPrefix("ARGUMENTS:") {
        // Arguments might span multiple lines if it's JSON
        argumentsJSON = trimmed.replacingOccurrences(of: "ARGUMENTS:", with: "")
          .trimmingCharacters(in: .whitespaces)

        // If arguments start with { but don't end with }, collect subsequent lines
        if argumentsJSON?.hasPrefix("{") == true && argumentsJSON?.hasSuffix("}") == false {
          var jsonString = argumentsJSON ?? ""
          for nextLine in lines.dropFirst(index + 1) {
            jsonString += "\n" + nextLine
            if nextLine.trimmingCharacters(in: .whitespaces).hasSuffix("}") {
              break
            }
          }
          argumentsJSON = jsonString
        }
      }
    }

    guard let name = toolName, !name.isEmpty  else {
      return nil
    }

    // Parse arguments JSON
    let args: [String: Any]
    if let jsonString = argumentsJSON,
      let data = jsonString.data(using: .utf8),
      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      args = parsed
    } else {
      args = [:]
    }

    return ParsedToolCall(
      toolName: name,
      arguments: args,
      rawResponse: response
    )
  }

  /// Check if response contains a tool call
  private func containsToolCall(_ response: String) -> Bool {
    return response.contains("TOOL_CALL:")
  }

  // Stream response with manual tool calling support
    func streamResponse(
        conversationId: String,
        prompt: String,
        systemInstructions: String = "You are a helpful assistant.",
        temperature: Double = 0.7,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) async {
        // Check availability
        guard isAvailable else {
      onError(getAvailabilityError())
      return
    }

    print("📨 [Apple Intelligence] Starting streaming response for conversation: \(conversationId)")
    print("💬 Prompt: \(prompt.prefix(100))...")

    // Tool calling loop
    var currentPrompt = prompt
    var toolCallDepth = 0
    var conversationContext: [String] = []

    while toolCallDepth < maxToolCallDepth {
      // Get or create session
      let session = getSession(
        conversationId: conversationId,
        systemInstructions: systemInstructions
      )

      // Create generation options
      let options = GenerationOptions(temperature: temperature)

      do {
        // Stream the response
        let stream = session.streamResponse(to: currentPrompt, options: options)

        var fullResponse = ""
        var previousContent = ""

        for try await snapshot in stream {
          await MainActor.run {
            let currentContent = snapshot.content
            if currentContent.hasPrefix(previousContent) {
              let delta = String(currentContent.dropFirst(previousContent.count))
              if !delta.isEmpty {
                onChunk(delta)
              }
            } else {
              onChunk(currentContent)
            }
            previousContent = currentContent
            fullResponse = currentContent
          }
        }

        print("📝 [Apple Intelligence] Full response: \(fullResponse.prefix(200))...")

        // Check if response contains a tool call
        if containsToolCall(fullResponse), let toolCall = parseToolCall(from: fullResponse) {
          toolCallDepth += 1
          print(
            "🔧 [Apple Intelligence] Tool call detected (\(toolCallDepth)/\(maxToolCallDepth)): \(toolCall.toolName)"
          )
          print("📋 Arguments: \(toolCall.arguments)")

          // Skip problematic wassette tools that cause infinite loops
          if toolCall.toolName.contains("component") || toolCall.toolName.contains("policy")
            || toolCall.toolName.contains("permission") || toolCall.toolName.contains("local_time")
          {
            print("⚠️ Skipping problematic tool: \(toolCall.toolName)")
            await MainActor.run {
              onChunk("\n\nI cannot use that tool. Answering directly instead.\n\n")
            }
            break
          }

          // Notify user that we're executing a tool
          await MainActor.run {
            onChunk("\n\n🔧 Executing tool: \(toolCall.toolName)...\n")
          }

          // Execute the tool
          do {
            let toolResult = try await MCPServerManager.shared.executeTool(
              name: toolCall.toolName,
              arguments: toolCall.arguments
            )
            print("✅ [Apple Intelligence] Tool execution successful")
            print("📊 Result length: \(toolResult.count) chars")

            // Check if result is empty
            let trimmedResult = toolResult.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedResult.isEmpty {
              print("⚠️ Tool returned empty result, stopping loop")
              await MainActor.run {
                onChunk("❌ Tool returned no data\n\n")
              }
              break
            }

            // Notify user of tool result
            await MainActor.run {
              onChunk("✅ Tool completed\n\n")
            }

            // Create new prompt with tool result - explicitly tell it to STOP calling tools
            currentPrompt = """
              TOOL RESULT:
              \(trimmedResult.prefix(2000))

              Based on this result, provide your final answer. DO NOT call any more tools.
              """

            // Clear the accumulated response and continue loop
            continue

          } catch {
            print("❌ [Apple Intelligence] Tool execution failed: \(error.localizedDescription)")
            await MainActor.run {
              onChunk("❌ Tool execution failed: \(error.localizedDescription)\n\n")
            }
            // Don't fail the entire conversation, just stop tool calling
            break
          }
        } else {
          // No tool call, we're done
          print("✅ [Apple Intelligence] Response completed (no tool calls)")
          break
        }

      } catch let error as LanguageModelSession.GenerationError {
        await MainActor.run {
          switch error {
          case .exceededContextWindowSize(let size):
            onError(
              AppleIntelligenceError.generationFailed(
                "Context window exceeded (\(size) tokens). Try reducing tool count or clearing conversation history."
              ))
          default:
            onError(AppleIntelligenceError.generationFailed(error.localizedDescription))
          }
        }
        return
      } catch {
        await MainActor.run {
          onError(AppleIntelligenceError.generationFailed(error.localizedDescription))
        }
        return
      }
    }

    // Check if we hit the tool call limit
    if toolCallDepth >= maxToolCallDepth {
      print("⚠️ [Apple Intelligence] Max tool call depth reached")
      await MainActor.run {
        onChunk("\n\n⚠️ Maximum tool call depth reached. Stopping to prevent infinite loop.\n")
      }
    }

    await MainActor.run {
      print("✅ [Apple Intelligence] Conversation completed")
            onComplete()
        }
    }

    // Non-streaming response
    func generateResponse(
        conversationId: String,
        prompt: String,
        systemInstructions: String = "You are a helpful assistant.",
        temperature: Double = 0.7,
        onComplete: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async {
        // Check availability
        guard isAvailable else {
            onError(getAvailabilityError())
            return
        }

        // Get or create session
        let session = getSession(
            conversationId: conversationId,
            systemInstructions: systemInstructions
        )

        // Create generation options
        let options = GenerationOptions(temperature: temperature)

        do {
            // Generate the response
            let response = try await session.respond(to: prompt, options: options)

            await MainActor.run {
                onComplete(response.content)
            }
        } catch {
            await MainActor.run {
                onError(AppleIntelligenceError.generationFailed(error.localizedDescription))
            }
        }
    }

    private func getAvailabilityError() -> Error {
        switch availability {
        case .available:
            return AppleIntelligenceError.unavailable("Unknown")
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return AppleIntelligenceError.deviceNotEligible
            case .appleIntelligenceNotEnabled:
                return AppleIntelligenceError.appleIntelligenceNotEnabled
            case .modelNotReady:
                return AppleIntelligenceError.modelNotReady
            @unknown default:
                return AppleIntelligenceError.unavailable("Unknown reason")
            }
        @unknown default:
            return AppleIntelligenceError.unavailable("Unknown status")
        }
    }
}

//
//  ToolTranscriptSanitizer.swift
//  ayna
//
//  Keeps only complete, locally paired tool-call rounds in persisted history.
//

import Foundation

enum ToolTranscriptSanitizer {
    static func sanitize(_ messages: [Message]) -> [Message] {
        var sanitized: [Message] = []
        var index = 0

        while index < messages.count {
            let message = messages[index]

            guard message.role == .assistant,
                  let toolCalls = message.toolCalls,
                  !toolCalls.isEmpty
            else {
                if message.role != .tool,
                   message.role != .assistant || message.hasMeaningfulNonToolTranscriptContent
                {
                    sanitized.append(message)
                }
                index += 1
                continue
            }

            var resultByCallID: [String: Message] = [:]
            var nextIndex = index + 1
            while nextIndex < messages.count, messages[nextIndex].role == .tool {
                let result = messages[nextIndex]
                if let callID = result.toolCalls?.first?.id,
                   resultByCallID[callID] == nil
                {
                    resultByCallID[callID] = result
                }
                nextIndex += 1
            }

            var seenCallIDs: Set<String> = []
            let validCalls = toolCalls.filter { call in
                resultByCallID[call.id] != nil && seenCallIDs.insert(call.id).inserted
            }

            var sanitizedAssistant = message
            sanitizedAssistant.toolCalls = validCalls.isEmpty ? nil : validCalls
            if !validCalls.isEmpty || sanitizedAssistant.hasMeaningfulNonToolTranscriptContent {
                sanitized.append(sanitizedAssistant)
            }
            for call in validCalls {
                if let result = resultByCallID[call.id] {
                    sanitized.append(result)
                }
            }

            index = nextIndex
        }

        return sanitized
    }
}

//
//  ToolExecutionResult.swift
//  ayna
//
//  Shared result data for one completed provider-requested tool call.
//

import Foundation

/// The completed output and display metadata for one provider-requested tool call.
struct ToolExecutionResult: Sendable {
    let callID: String
    let toolName: String
    let arguments: [String: AnyCodable]
    let output: String
    let citations: [CitationReference]

    init(
        callID: String,
        toolName: String,
        arguments: [String: AnyCodable],
        output: String,
        citations: [CitationReference] = []
    ) {
        self.callID = callID
        self.toolName = toolName
        self.arguments = arguments
        self.output = output
        self.citations = citations
    }

    /// Creates the persisted tool-result message used as provider history.
    func makeMessage() -> Message {
        var message = Message(role: .tool, content: output)
        message.toolCalls = [
            MCPToolCall(
                id: callID,
                toolName: toolName,
                arguments: arguments,
                result: output
            )
        ]
        return message
    }

    /// Combines citation lists in callback registration order and assigns stable numbers.
    static func combinedCitations(from results: [ToolExecutionResult]) -> [CitationReference] {
        results
            .flatMap(\.citations)
            .enumerated()
            .map { index, citation in
                CitationReference(
                    number: index + 1,
                    title: citation.title,
                    url: citation.url,
                    favicon: citation.favicon
                )
            }
    }
}

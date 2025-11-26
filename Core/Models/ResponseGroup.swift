//
//  ResponseGroup.swift
//  ayna
//
//  Created on 11/25/25.
//

import Foundation

/// Status of a response in a multi-model response group
enum ResponseGroupStatus: String, Codable, Equatable {
    case streaming // Currently receiving chunks
    case completed // Finished streaming
    case failed // Error occurred
    case selected // User selected this response
}

/// An entry tracking a single model's response within a ResponseGroup
struct ResponseGroupEntry: Identifiable, Codable, Equatable {
    let id: UUID // Same as the Message.id
    let modelName: String
    var status: ResponseGroupStatus
}

/// Represents a group of parallel responses from multiple AI models
/// for a single user prompt in multi-model mode.
struct ResponseGroup: Identifiable, Codable, Equatable {
    let id: UUID
    let userMessageId: UUID // The user message that triggered these responses
    var responses: [ResponseGroupEntry] // All model responses in this group
    var selectedResponseId: UUID? // The response the user selected to continue with
    let createdAt: Date

    // Type aliases for backward compatibility
    typealias ResponseEntry = ResponseGroupEntry
    typealias ResponseStatus = ResponseGroupStatus

    init(
        id: UUID = UUID(),
        userMessageId: UUID,
        responses: [ResponseEntry] = [],
        selectedResponseId: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.userMessageId = userMessageId
        self.responses = responses
        self.selectedResponseId = selectedResponseId
        self.createdAt = createdAt
    }

    /// Check if all responses have completed (or failed)
    var isComplete: Bool {
        responses.allSatisfy { $0.status == .completed || $0.status == .failed || $0.status == .selected }
    }

    /// Check if user has selected a response
    var hasSelection: Bool {
        selectedResponseId != nil
    }

    /// Get the selected response entry
    var selectedEntry: ResponseEntry? {
        responses.first { $0.id == selectedResponseId }
    }

    /// Mark a response as selected
    mutating func selectResponse(_ messageId: UUID) {
        selectedResponseId = messageId
        // Update status of all entries
        for index in responses.indices where responses[index].id == messageId {
            responses[index].status = .selected
        }
    }

    /// Update status for a specific response
    mutating func updateStatus(for messageId: UUID, status: ResponseGroupStatus) {
        if let index = responses.firstIndex(where: { $0.id == messageId }) {
            responses[index].status = status
        }
    }

    /// Add a new response entry
    mutating func addResponse(messageId: UUID, modelName: String, status: ResponseGroupStatus = .streaming) {
        let entry = ResponseEntry(id: messageId, modelName: modelName, status: status)
        responses.append(entry)
    }
}

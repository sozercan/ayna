//
//  Message.swift
//  ayna
//
//  Created on 11/2/25.
//

import Foundation

struct Message: Identifiable, Codable, Equatable {
    let id: UUID
    var role: Role
    var content: String
    let timestamp: Date
    var isLiked: Bool
    var toolCalls: [MCPToolCall]?

    enum Role: String, Codable {
        case system
        case user
        case assistant
        case tool
    }

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        timestamp: Date = Date(),
        isLiked: Bool = false,
        toolCalls: [MCPToolCall]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isLiked = isLiked
        self.toolCalls = toolCalls
    }
}

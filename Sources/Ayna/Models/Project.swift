//
//  Project.swift
//  Ayna
//
//  Lightweight project model for grouping conversations by workspace.
//

import Foundation

struct Project: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var workspaceRoot: String
    var defaultModel: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        workspaceRoot: String,
        defaultModel: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.workspaceRoot = workspaceRoot
        self.defaultModel = defaultModel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case workspaceRoot
        case defaultModel
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        workspaceRoot = try container.decode(String.self, forKey: .workspaceRoot)
        defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

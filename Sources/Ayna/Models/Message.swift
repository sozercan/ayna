//
//  Message.swift
//  ayna
//
//  Created on 11/2/25.
//

import Foundation

// MARK: - Citation Reference

/// Represents a citation source from web search results
struct CitationReference: Codable, Equatable, Sendable {
    let number: Int
    let title: String
    let url: String
    let favicon: String?

    init(number: Int, title: String, url: String, favicon: String? = nil) {
        self.number = number
        self.title = title
        self.url = url
        self.favicon = favicon
    }
}

struct Message: Identifiable, Codable, Equatable {
    let id: UUID
    var role: Role
    var content: String
    let timestamp: Date
    var isLiked: Bool
    #if !os(watchOS)
        var toolCalls: [MCPToolCall]?
    #endif
    var model: String? // Track which model generated this message

    // Multi-model response support
    var responseGroupId: UUID? // Groups parallel responses together
    var isSelectedResponse: Bool? // Is this the chosen response in its group?
    #if !os(watchOS)
        var pendingToolCalls: [MCPToolCall]? // Tool calls deferred until response selection
    #endif

    // Image generation support
    var mediaType: MediaType?
    var imageData: Data?
    var imagePath: String? // Path relative to AttachmentStorage

    /// File attachments for vision/multimodal support
    var attachments: [FileAttachment]?

    /// Reasoning/thinking support for o1/o3 models
    var reasoning: String?

    /// Web search citation support
    var citations: [CitationReference]?

    /// Edit tracking support
    var isEdited: Bool
    var editedAt: Date?

    enum MediaType: String, Codable {
        case image
    }

    struct FileAttachment: Codable, Equatable {
        let fileName: String
        let mimeType: String
        var data: Data?
        var localPath: String? // Path relative to AttachmentStorage

        /// Helper to get data regardless of storage method
        @MainActor
        var content: Data? {
            if let data { return data }
            if let path = localPath {
                return Message.attachmentLoader?(path)
            }
            return nil
        }
    }

    enum Role: String, Codable {
        case system
        case user
        case assistant
        case tool
    }

    #if os(watchOS)
        init(
            id: UUID = UUID(),
            role: Role,
            content: String,
            timestamp: Date = Date(),
            isLiked: Bool = false,
            model: String? = nil,
            responseGroupId: UUID? = nil,
            isSelectedResponse: Bool? = nil,
            mediaType: MediaType? = nil,
            imageData: Data? = nil,
            imagePath: String? = nil,
            attachments: [FileAttachment]? = nil,
            reasoning: String? = nil,
            citations: [CitationReference]? = nil,
            isEdited: Bool = false,
            editedAt: Date? = nil
        ) {
            self.id = id
            self.role = role
            self.content = content
            self.timestamp = timestamp
            self.isLiked = isLiked
            self.model = model
            self.responseGroupId = responseGroupId
            self.isSelectedResponse = isSelectedResponse
            self.mediaType = mediaType
            self.imageData = imageData
            self.imagePath = imagePath
            self.attachments = attachments
            self.reasoning = reasoning
            self.citations = citations
            self.isEdited = isEdited
            self.editedAt = editedAt
        }
    #else
        init(
            id: UUID = UUID(),
            role: Role,
            content: String,
            timestamp: Date = Date(),
            isLiked: Bool = false,
            toolCalls: [MCPToolCall]? = nil,
            model: String? = nil,
            responseGroupId: UUID? = nil,
            isSelectedResponse: Bool? = nil,
            pendingToolCalls: [MCPToolCall]? = nil,
            mediaType: MediaType? = nil,
            imageData: Data? = nil,
            imagePath: String? = nil,
            attachments: [FileAttachment]? = nil,
            reasoning: String? = nil,
            citations: [CitationReference]? = nil,
            isEdited: Bool = false,
            editedAt: Date? = nil
        ) {
            self.id = id
            self.role = role
            self.content = content
            self.timestamp = timestamp
            self.isLiked = isLiked
            self.toolCalls = toolCalls
            self.model = model
            self.responseGroupId = responseGroupId
            self.isSelectedResponse = isSelectedResponse
            self.pendingToolCalls = pendingToolCalls
            self.mediaType = mediaType
            self.imageData = imageData
            self.imagePath = imagePath
            self.attachments = attachments
            self.reasoning = reasoning
            self.citations = citations
            self.isEdited = isEdited
            self.editedAt = editedAt
        }
    #endif

    // MARK: - Codable (backward compatibility)

    #if os(watchOS)
        private enum CodingKeys: String, CodingKey {
            case id, role, content, timestamp, isLiked, model
            case responseGroupId, isSelectedResponse
            case mediaType, imageData, imagePath, attachments, reasoning, citations
            case isEdited, editedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            role = try container.decode(Role.self, forKey: .role)
            content = try container.decode(String.self, forKey: .content)
            timestamp = try container.decode(Date.self, forKey: .timestamp)
            isLiked = try container.decode(Bool.self, forKey: .isLiked)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            // Multi-model fields (backward compatibility)
            responseGroupId = try container.decodeIfPresent(UUID.self, forKey: .responseGroupId)
            isSelectedResponse = try container.decodeIfPresent(Bool.self, forKey: .isSelectedResponse)
            // Media fields
            mediaType = try container.decodeIfPresent(MediaType.self, forKey: .mediaType)
            imageData = try container.decodeIfPresent(Data.self, forKey: .imageData)
            imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath)
            attachments = try container.decodeIfPresent([FileAttachment].self, forKey: .attachments)
            reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
            citations = try container.decodeIfPresent([CitationReference].self, forKey: .citations)
            // Edit tracking (backward compatibility - defaults to false for old messages)
            isEdited = try container.decodeIfPresent(Bool.self, forKey: .isEdited) ?? false
            editedAt = try container.decodeIfPresent(Date.self, forKey: .editedAt)
        }
    #else
        private enum CodingKeys: String, CodingKey {
            case id, role, content, timestamp, isLiked, toolCalls, model
            case responseGroupId, isSelectedResponse, pendingToolCalls
            case mediaType, imageData, imagePath, attachments, reasoning, citations
            case isEdited, editedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            role = try container.decode(Role.self, forKey: .role)
            content = try container.decode(String.self, forKey: .content)
            timestamp = try container.decode(Date.self, forKey: .timestamp)
            isLiked = try container.decode(Bool.self, forKey: .isLiked)
            toolCalls = try container.decodeIfPresent([MCPToolCall].self, forKey: .toolCalls)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            // Multi-model fields (backward compatibility)
            responseGroupId = try container.decodeIfPresent(UUID.self, forKey: .responseGroupId)
            isSelectedResponse = try container.decodeIfPresent(Bool.self, forKey: .isSelectedResponse)
            pendingToolCalls = try container.decodeIfPresent([MCPToolCall].self, forKey: .pendingToolCalls)
            // Media fields
            mediaType = try container.decodeIfPresent(MediaType.self, forKey: .mediaType)
            imageData = try container.decodeIfPresent(Data.self, forKey: .imageData)
            imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath)
            attachments = try container.decodeIfPresent([FileAttachment].self, forKey: .attachments)
            reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
            citations = try container.decodeIfPresent([CitationReference].self, forKey: .citations)
            // Edit tracking (backward compatibility - defaults to false for old messages)
            isEdited = try container.decodeIfPresent(Bool.self, forKey: .isEdited) ?? false
            editedAt = try container.decodeIfPresent(Date.self, forKey: .editedAt)
        }
    #endif

    /// Helper to get image data regardless of storage method
    @MainActor
    var effectiveImageData: Data? {
        if let data = imageData { return data }
        if let path = imagePath {
            return Message.attachmentLoader?(path)
        }
        return nil
    }

    /// Static loader to decouple from AttachmentStorage
    @MainActor static var attachmentLoader: ((String) -> Data?)?
}

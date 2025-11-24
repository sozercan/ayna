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
    var model: String? // Track which model generated this message

    // Image generation support
    var mediaType: MediaType?
    var imageData: Data?
    var imagePath: String? // Path relative to AttachmentStorage

    // File attachments for vision/multimodal support
    var attachments: [FileAttachment]?

    // Reasoning/thinking support for o1/o3 models
    var reasoning: String?

    enum MediaType: String, Codable {
        case image
    }

    struct FileAttachment: Codable, Equatable {
        let fileName: String
        let mimeType: String
        var data: Data?
        var localPath: String? // Path relative to AttachmentStorage

        // Helper to get data regardless of storage method
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

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        timestamp: Date = Date(),
        isLiked: Bool = false,
        toolCalls: [MCPToolCall]? = nil,
        model: String? = nil,
        mediaType: MediaType? = nil,
        imageData: Data? = nil,
        imagePath: String? = nil,
        attachments: [FileAttachment]? = nil,
        reasoning: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isLiked = isLiked
        self.toolCalls = toolCalls
        self.model = model
        self.mediaType = mediaType
        self.imageData = imageData
        self.imagePath = imagePath
        self.attachments = attachments
        self.reasoning = reasoning
    }

    // Helper to get image data regardless of storage method
  @MainActor
    var effectiveImageData: Data? {
        if let data = imageData { return data }
        if let path = imagePath {
      return Message.attachmentLoader?(path)
        }
        return nil
    }

  // Static loader to decouple from AttachmentStorage
  @MainActor static var attachmentLoader: ((String) -> Data?)?
}

//
//  MCPModels.swift
//  ayna
//
//  Created on 11/3/25.
//

import Foundation

// MARK: - MCP Server Configuration

struct MCPServerConfig: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var command: String
    var args: [String]
    var env: [String: String]
    var enabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.enabled = enabled
    }
}

// MARK: - MCP Tool

struct MCPTool: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let description: String
    let inputSchema: JSONSchema
    let serverName: String // Which MCP server provides this tool

    init(
        id: UUID = UUID(),
        name: String,
        description: String,
        inputSchema: JSONSchema,
        serverName: String
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.serverName = serverName
    }

    /// Convert to OpenAI function format
    func toOpenAIFunction() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": inputSchema.toJSON()
            ]
        ]
    }
}

// MARK: - JSON Schema

struct JSONSchema: Codable, Equatable, Sendable {
    let type: String
    let properties: [String: AnyCodable]?
    let required: [String]?
    let items: AnyCodable?

    struct Property: Codable, Equatable, Sendable {
        let type: String
        let description: String?
        let `enum`: [String]?

        static func == (lhs: Property, rhs: Property) -> Bool {
            lhs.type == rhs.type &&
                lhs.description == rhs.description &&
                lhs.enum == rhs.enum
        }
    }

    func toJSON() -> [String: Any] {
        var result: [String: Any] = ["type": type]

        if let properties {
            var propsDict: [String: Any] = [:]
            for (key, prop) in properties {
                propsDict[key] = prop.value
            }
            result["properties"] = propsDict
        }

        if let required {
            result["required"] = required
        }

        if let items {
            result["items"] = items.value
        }

        return result
    }
}

extension JSONSchema.Property {
    func toJSON() -> [String: Any] {
        var result: [String: Any] = ["type": type]

        if let description {
            result["description"] = description
        }

        if let `enum` {
            result["enum"] = `enum`
        }

        return result
    }
}

// MARK: - MCP Resource

struct MCPResource: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let uri: String
    let name: String
    let description: String?
    let mimeType: String?
    let serverName: String

    init(
        id: UUID = UUID(),
        uri: String,
        name: String,
        description: String? = nil,
        mimeType: String? = nil,
        serverName: String
    ) {
        self.id = id
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
        self.serverName = serverName
    }
}

// MARK: - MCP JSON-RPC Messages

struct MCPRequest: Codable, Sendable {
    let jsonrpc: String = "2.0"
    let id: Int
    let method: String
    let params: [String: AnyCodable]?

    init(id: Int, method: String, params: [String: AnyCodable]? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

struct MCPResponse: Codable, Sendable {
    let jsonrpc: String
    let id: Int?
    let result: AnyCodable?
    let error: MCPError?
}

struct MCPError: Codable, Sendable {
    let code: Int
    let message: String
    let data: AnyCodable?
}

// MARK: - Tool Call Result

struct MCPToolCall: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let toolName: String
    let arguments: [String: AnyCodable]
    var result: String?
    var error: String?
    let timestamp: Date

    init(
        id: String = UUID().uuidString,
        toolName: String,
        arguments: [String: AnyCodable],
        result: String? = nil,
        error: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
        self.error = error
        self.timestamp = timestamp
    }
}

// MARK: - AnyCodable Helper

struct AnyCodable: Codable, Equatable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            value = dictionary.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case let (lhs as Bool, rhs as Bool):
            lhs == rhs
        case let (lhs as Int, rhs as Int):
            lhs == rhs
        case let (lhs as Double, rhs as Double):
            lhs == rhs
        case let (lhs as String, rhs as String):
            lhs == rhs
        default:
            false
        }
    }
}

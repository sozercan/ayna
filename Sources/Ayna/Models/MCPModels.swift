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

    /// Convert to OpenAI function format, optionally under a model-facing alias.
    func toOpenAIFunction(exposedName: String? = nil) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": exposedName ?? name,
                "description": description,
                "parameters": inputSchema.toJSON()
            ]
        ]
    }
}

/// Names MCP tools are offered to the model under, bound for the whole session.
///
/// A tool keeps its own name unless that name is reserved (served by Ayna) or already taken by
/// another server's tool; then it becomes `server__tool`, cleaned to the `^[A-Za-z0-9_-]{1,64}$`
/// form function-calling APIs accept. Once an alias is bound to a server and tool it is never
/// given to anything else, so a call made against an older tool list either reaches the same
/// tool or fails, and never runs on a different server.
struct MCPToolNaming {
    private var aliasByKey: [String: String] = [:]
    private var keyByAlias: [String: String] = [:]

    static func key(server: String, tool: String) -> String {
        "\(server)\u{0}\(tool)"
    }

    /// Model-facing name for each tool, by tool ID.
    mutating func assign(_ tools: [MCPTool], reserved: Set<String>) -> [UUID: String] {
        let ordered = tools.sorted { Self.key(server: $0.serverName, tool: $0.name) < Self.key(server: $1.serverName, tool: $1.name) }
        var result: [UUID: String] = [:]
        var taken = reserved

        // Keep every alias already bound to a tool that is still here.
        for tool in ordered {
            let key = Self.key(server: tool.serverName, tool: tool.name)
            if let alias = aliasByKey[key], !taken.contains(alias) {
                result[tool.id] = alias
                taken.insert(alias)
            }
        }

        let unassigned = ordered.filter { result[$0.id] == nil }
        let rawNameCounts = unassigned.reduce(into: [String: Int]()) { $0[$1.name, default: 0] += 1 }
        for tool in unassigned {
            let key = Self.key(server: tool.serverName, tool: tool.name)
            let alias: String
            if rawNameCounts[tool.name] == 1, isAvailable(tool.name, for: key, taken: taken) {
                alias = tool.name
            } else {
                let base = Self.sanitized("\(tool.serverName)__\(tool.name)")
                var candidate = base
                var suffix = 2
                while !isAvailable(candidate, for: key, taken: taken) {
                    let tail = "_\(suffix)"
                    candidate = String(base.prefix(64 - tail.count)) + tail
                    suffix += 1
                }
                alias = candidate
            }
            result[tool.id] = alias
            taken.insert(alias)
            aliasByKey[key] = alias
            keyByAlias[alias] = key
        }
        return result
    }

    private func isAvailable(_ alias: String, for key: String, taken: Set<String>) -> Bool {
        !taken.contains(alias) && (keyByAlias[alias] == nil || keyByAlias[alias] == key)
    }

    private static func sanitized(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return String(String(name.map { allowed.contains($0) ? $0 : "_" }).prefix(64))
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

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }

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

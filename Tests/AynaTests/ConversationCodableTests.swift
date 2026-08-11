@testable import Ayna
import Foundation
import Testing

@Suite("Conversation Codable Tests", .tags(.fast))
struct ConversationCodableTests {
    @Test
    func `legacy nonempty system prompt decodes as custom`() throws {
        let data = legacyConversationData(
            systemPromptMember: ",\n    \"systemPrompt\": \"Answer concisely.\""
        )

        let conversation = try JSONDecoder().decode(Conversation.self, from: data)

        #expect(conversation.systemPromptMode == .custom("Answer concisely."))
        #expect(conversation.temperature == 0.25)
        #expect(conversation.reasoningConfiguration == .automatic)
    }

    @Test(
        arguments: LegacyInheritingSystemPrompt.allCases
    )
    func `legacy absent, null, or empty system prompt decodes as inherit global`(_ legacyPrompt: LegacyInheritingSystemPrompt) throws {
        let data = legacyConversationData(systemPromptMember: legacyPrompt.jsonMember)

        let conversation = try JSONDecoder().decode(Conversation.self, from: data)

        #expect(conversation.systemPromptMode == .inheritGlobal)
        #expect(conversation.temperature == 0.25)
        #expect(conversation.reasoningConfiguration == .automatic)
    }

    @Test
    func `current schema round-trips`() throws {
        let id = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let original = Conversation(
            id: id,
            title: "Current schema",
            messages: [],
            createdAt: Date(timeIntervalSinceReferenceDate: 1000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 2000),
            model: "gpt-5",
            systemPromptMode: .disabled,
            temperature: 0.5,
            reasoningConfiguration: ModelReasoningConfiguration(
                activation: .enabled,
                effort: .xhigh,
                openAIMode: .pro,
                openAIContext: .allTurns,
                summary: .detailed
            ),
            multiModelEnabled: true,
            activeModels: ["gpt-5", "claude-sonnet-4"],
            responseGroups: []
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Conversation.self, from: data)

        #expect(decoded == original)
    }

    @Test
    func `metadata round-trip preserves conversation reasoning`() throws {
        let configuration = ModelReasoningConfiguration(
            activation: .enabled,
            effort: .high,
            summary: .concise
        )
        let conversation = Conversation(
            title: "Reasoning metadata",
            model: "gpt-5.6",
            reasoningConfiguration: configuration
        )
        let metadata = ConversationMetadata(conversation: conversation)

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(ConversationMetadata.self, from: data)

        #expect(metadata.reasoningConfiguration == configuration)
        #expect(decoded.reasoningConfiguration == configuration)
    }

    @Test
    func `legacy metadata without reasoning decodes as automatic`() throws {
        let id = try #require(UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF"))
        let data = Data(
            """
            {
                "id": "\(id.uuidString)",
                "title": "Legacy metadata",
                "createdAt": 1000,
                "updatedAt": 2000,
                "model": "gpt-4o",
                "systemPromptMode": {"type": "inheritGlobal"},
                "temperature": 0.7,
                "multiModelEnabled": false,
                "activeModels": [],
                "messageCount": 0,
                "responseGroupCount": 0,
                "lastMessagePreview": "",
                "searchableText": "Legacy metadata"
            }
            """.utf8
        )

        let metadata = try JSONDecoder().decode(ConversationMetadata.self, from: data)

        #expect(metadata.reasoningConfiguration == .automatic)
    }

    @Test
    func `current system prompt mode takes precedence over legacy prompt`() throws {
        let systemPromptMember = """
        ,
            "systemPrompt": "Legacy prompt",
            "systemPromptMode": {"type": "disabled"}
        """
        let data = legacyConversationData(systemPromptMember: systemPromptMember)

        let conversation = try JSONDecoder().decode(Conversation.self, from: data)

        #expect(conversation.systemPromptMode == .disabled)
    }

    @Test
    func `malformed current system prompt mode does not fall back to legacy prompt`() {
        let systemPromptMember = """
        ,
            "systemPrompt": "Valid legacy prompt",
            "systemPromptMode": null
        """
        let data = legacyConversationData(systemPromptMember: systemPromptMember)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Conversation.self, from: data)
        }
    }
}

enum LegacyInheritingSystemPrompt: CaseIterable, CustomTestStringConvertible, Sendable {
    case absent
    case null
    case empty

    var jsonMember: String {
        switch self {
        case .absent:
            ""
        case .null:
            ",\n    \"systemPrompt\": null"
        case .empty:
            ",\n    \"systemPrompt\": \"\""
        }
    }

    var testDescription: String {
        switch self {
        case .absent:
            "absent"
        case .null:
            "null"
        case .empty:
            "empty"
        }
    }
}

private func legacyConversationData(systemPromptMember: String) -> Data {
    Data(
        """
        {
            "id": "11111111-2222-3333-4444-555555555555",
            "title": "Legacy conversation",
            "messages": [],
            "createdAt": 1000,
            "updatedAt": 2000,
            "model": "gpt-4o"\(systemPromptMember),
            "temperature": 0.25
        }
        """.utf8
    )
}

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
    }

    @Test(
        arguments: LegacyInheritingSystemPrompt.allCases
    )
    func `legacy absent, null, or empty system prompt decodes as inherit global`(_ legacyPrompt: LegacyInheritingSystemPrompt) throws {
        let data = legacyConversationData(systemPromptMember: legacyPrompt.jsonMember)

        let conversation = try JSONDecoder().decode(Conversation.self, from: data)

        #expect(conversation.systemPromptMode == .inheritGlobal)
        #expect(conversation.temperature == 0.25)
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
            multiModelEnabled: true,
            activeModels: ["gpt-5", "claude-sonnet-4"],
            responseGroups: []
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Conversation.self, from: data)

        #expect(decoded == original)
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

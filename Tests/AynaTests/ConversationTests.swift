@testable import Ayna
import Foundation
import Testing

@Suite("Conversation Tests", .tags(.fast))
struct ConversationTests {
    @Test("Legacy decode without projectId defaults to nil")
    func legacyDecodeWithoutProjectId() throws {
        let conversation = TestHelpers.sampleConversation()
        let encoded = try JSONEncoder().encode(conversation)
        let jsonObject = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        var legacyObject = jsonObject
        legacyObject.removeValue(forKey: "projectId")

        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decoded = try JSONDecoder().decode(Conversation.self, from: legacyData)

        #expect(decoded.projectId == nil)
        #expect(decoded.id == conversation.id)
        #expect(decoded.title == conversation.title)
    }

    @Test("Encode and decode preserves projectId")
    func encodeDecodeRoundTripWithProjectId() throws {
        let projectId = UUID()
        let conversation = Conversation(
            title: "Project Chat",
            messages: [Message(role: .user, content: "Hello")],
            model: "gpt-4o",
            projectId: projectId
        )

        let encoded = try JSONEncoder().encode(conversation)
        let decoded = try JSONDecoder().decode(Conversation.self, from: encoded)

        #expect(decoded.projectId == projectId)
        #expect(decoded.title == "Project Chat")
        #expect(decoded.messages.count == 1)
    }
}

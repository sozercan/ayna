@testable import Ayna
import Foundation
import Testing

@Suite("WatchConversation Tests", .tags(.fast))
struct WatchConversationTests {
    @Test("Initialize from Conversation preserves all properties")
    func initFromConversationPreservesAllProperties() {
        let convId = UUID()
        let createdAt = Date()
        let model = "gpt-4o"
        let title = "Test Chat"

        var conversation = Conversation(
            id: convId,
            title: title,
            createdAt: createdAt,
            model: model
        )
        conversation.addMessage(Message(role: .user, content: "Hello"))
        conversation.addMessage(Message(role: .assistant, content: "Hi!", model: model))

        let watchConv = WatchConversation(from: conversation)

        #expect(watchConv.id == convId)
        #expect(watchConv.title == title)
        #expect(watchConv.model == model)
        #expect(watchConv.messages.count == 2)
        #expect(abs(watchConv.createdAt.timeIntervalSince1970 - createdAt.timeIntervalSince1970) < 0.001)
    }

    @Test("Initialize from Conversation limits messages to 20")
    func initFromConversationLimitsMessages() {
        var conversation = Conversation(title: "Long Chat", model: "gpt-4o")

        // Add 30 messages
        for idx in 1 ... 30 {
            conversation.addMessage(Message(role: .user, content: "Message \(idx)"))
        }

        let watchConv = WatchConversation(from: conversation)

        #expect(watchConv.messages.count == 20, "Should limit to 20 messages")
        // Should keep the last 20 messages (11-30)
        #expect(watchConv.messages.first?.content == "Message 11")
        #expect(watchConv.messages.last?.content == "Message 30")
    }

    @Test("Convert to Conversation restores all properties")
    func convertToConversation() {
        let convId = UUID()
        let createdAt = Date()
        let model = "gpt-4o"
        let title = "Test Chat"

        var conversation = Conversation(
            id: convId,
            title: title,
            createdAt: createdAt,
            model: model
        )
        conversation.addMessage(Message(role: .user, content: "Hello"))
        conversation.addMessage(Message(role: .assistant, content: "Hi!", model: model))

        // Round trip
        let watchConv = WatchConversation(from: conversation)
        let restored = watchConv.toConversation()

        #expect(restored.id == convId)
        #expect(restored.title == title)
        #expect(restored.model == model)
        #expect(restored.messages.count == 2)
        #expect(restored.messages[0].content == "Hello")
        #expect(restored.messages[1].content == "Hi!")
    }

    @Test("Codable encoding and decoding")
    func codableEncodingDecoding() throws {
        let convId = UUID()
        let createdAt = Date()

        var conversation = Conversation(
            id: convId,
            title: "Test",
            createdAt: createdAt,
            model: "gpt-4o"
        )
        conversation.addMessage(Message(role: .user, content: "Test message"))

        let watchConv = WatchConversation(from: conversation)

        let encoder = JSONEncoder()
        let data = try encoder.encode(watchConv)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(WatchConversation.self, from: data)

        #expect(decoded.id == convId)
        #expect(decoded.title == "Test")
        #expect(decoded.model == "gpt-4o")
        #expect(decoded.messages.count == 1)
    }

    @Test("Empty messages array")
    func emptyMessagesArray() {
        let conversation = Conversation(title: "Empty Chat", model: "gpt-4o")
        let watchConv = WatchConversation(from: conversation)

        #expect(watchConv.messages.isEmpty)

        let restored = watchConv.toConversation()
        #expect(restored.messages.isEmpty)
    }

    @Test("Preserves message order")
    func preservesMessageOrder() {
        var conversation = Conversation(title: "Ordered Chat", model: "gpt-4o")

        for idx in 1 ... 5 {
            conversation.addMessage(Message(role: .user, content: "Message \(idx)"))
        }

        let watchConv = WatchConversation(from: conversation)
        let restored = watchConv.toConversation()

        for idx in 0 ..< 5 {
            #expect(restored.messages[idx].content == "Message \(idx + 1)")
        }
    }
}

@Suite("WatchMessage Tests")
struct WatchMessageTests {
    @Test("Initialize from Message preserves all properties")
    func initFromMessagePreservesAllProperties() {
        let msgId = UUID()
        let timestamp = Date()
        let content = "Hello, world!"
        let model = "gpt-4o"

        let message = Message(
            id: msgId,
            role: .assistant,
            content: content,
            timestamp: timestamp,
            model: model
        )

        let watchMsg = WatchMessage(from: message)

        #expect(watchMsg.id == msgId)
        #expect(watchMsg.role == "assistant")
        #expect(watchMsg.content == content)
        #expect(watchMsg.model == model)
        #expect(abs(watchMsg.timestamp.timeIntervalSince1970 - timestamp.timeIntervalSince1970) < 0.001)
    }

    @Test("Convert to Message restores all properties")
    func convertToMessage() {
        let msgId = UUID()
        let timestamp = Date()
        let content = "Test content"
        let model = "gpt-4o"

        let original = Message(
            id: msgId,
            role: .user,
            content: content,
            timestamp: timestamp,
            model: model
        )

        // Round trip
        let watchMsg = WatchMessage(from: original)
        let restored = watchMsg.toMessage()

        #expect(restored.id == msgId)
        #expect(restored.role == .user)
        #expect(restored.content == content)
        #expect(restored.model == model)
        #expect(abs(restored.timestamp.timeIntervalSince1970 - timestamp.timeIntervalSince1970) < 0.001)
    }

    @Test("Role conversion user")
    func roleConversionUser() {
        let message = Message(role: .user, content: "Test")
        let watchMsg = WatchMessage(from: message)

        #expect(watchMsg.role == "user")
        #expect(watchMsg.toMessage().role == .user)
    }

    @Test("Role conversion assistant")
    func roleConversionAssistant() {
        let message = Message(role: .assistant, content: "Test")
        let watchMsg = WatchMessage(from: message)

        #expect(watchMsg.role == "assistant")
        #expect(watchMsg.toMessage().role == .assistant)
    }

    @Test("Role conversion system")
    func roleConversionSystem() {
        let message = Message(role: .system, content: "Test")
        let watchMsg = WatchMessage(from: message)

        #expect(watchMsg.role == "system")
        #expect(watchMsg.toMessage().role == .system)
    }

    @Test("Role conversion tool")
    func roleConversionTool() {
        let message = Message(role: .tool, content: "Test")
        let watchMsg = WatchMessage(from: message)

        #expect(watchMsg.role == "tool")
        #expect(watchMsg.toMessage().role == .tool)
    }

    @Test("Codable encoding and decoding")
    func codableEncodingDecoding() throws {
        let msgId = UUID()
        let timestamp = Date()

        let message = Message(
            id: msgId,
            role: .assistant,
            content: "Test message",
            timestamp: timestamp,
            model: "gpt-4o"
        )

        let watchMsg = WatchMessage(from: message)

        let encoder = JSONEncoder()
        let data = try encoder.encode(watchMsg)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(WatchMessage.self, from: data)

        #expect(decoded.id == msgId)
        #expect(decoded.role == "assistant")
        #expect(decoded.content == "Test message")
        #expect(decoded.model == "gpt-4o")
    }

    @Test("Nil model handling")
    func nilModelHandling() {
        let message = Message(role: .user, content: "Test")
        let watchMsg = WatchMessage(from: message)

        #expect(watchMsg.model == nil)

        let restored = watchMsg.toMessage()
        #expect(restored.model == nil)
    }

    @Test("Empty content handling")
    func emptyContentHandling() {
        let message = Message(role: .assistant, content: "")
        let watchMsg = WatchMessage(from: message)

        #expect(watchMsg.content.isEmpty)

        let restored = watchMsg.toMessage()
        #expect(restored.content.isEmpty)
    }

    @Test("Special characters in content")
    func specialCharactersInContent() throws {
        let specialContent = "Hello 👋 world! \n\t\"quoted\" and 'apostrophe' with émojis 🎉"
        let message = Message(role: .user, content: specialContent)
        let watchMsg = WatchMessage(from: message)

        // Encode and decode to test JSON handling
        let data = try JSONEncoder().encode(watchMsg)
        let decoded = try JSONDecoder().decode(WatchMessage.self, from: data)

        #expect(decoded.content == specialContent)
    }
}

@Suite("WatchConvern Array Conversion Tests")
struct WatchConversationArrayTests {
    @Test("Convert multiple conversations")
    func convertMultipleConversations() {
        var conversations: [Conversation] = []

        for idx in 1 ... 3 {
            var conv = Conversation(title: "Chat \(idx)", model: "gpt-4o")
            conv.addMessage(Message(role: .user, content: "Message in chat \(idx)"))
            conversations.append(conv)
        }

        let watchConversations = conversations.map { WatchConversation(from: $0) }

        #expect(watchConversations.count == 3)

        for (index, watchConv) in watchConversations.enumerated() {
            #expect(watchConv.title == "Chat \(index + 1)")
            #expect(watchConv.messages.count == 1)
            #expect(watchConv.messages.first?.content == "Message in chat \(index + 1)")
        }
    }

    @Test("Round trip array of conversations")
    func roundTripArrayOfConversations() {
        var conversations: [Conversation] = []

        for idx in 1 ... 5 {
            var conv = Conversation(title: "Chat \(idx)", model: "gpt-4o")
            conv.addMessage(Message(role: .user, content: "Hello \(idx)"))
            conv.addMessage(Message(role: .assistant, content: "Hi \(idx)!"))
            conversations.append(conv)
        }

        // Convert to watch format
        let watchConversations = conversations.map { WatchConversation(from: $0) }

        // Convert back
        let restored = watchConversations.map { $0.toConversation() }

        #expect(restored.count == 5)

        for (index, conv) in restored.enumerated() {
            #expect(conv.title == "Chat \(index + 1)")
            #expect(conv.messages.count == 2)
            #expect(conv.messages[0].content == "Hello \(index + 1)")
            #expect(conv.messages[1].content == "Hi \(index + 1)!")
        }
    }

    @Test("Encode and decode array")
    func encodeAndDecodeArray() throws {
        var conversations: [Conversation] = []

        for idx in 1 ... 3 {
            var conv = Conversation(title: "Chat \(idx)", model: "gpt-4o")
            conv.addMessage(Message(role: .user, content: "Message \(idx)"))
            conversations.append(conv)
        }

        let watchConversations = conversations.map { WatchConversation(from: $0) }

        let data = try JSONEncoder().encode(watchConversations)
        let decoded = try JSONDecoder().decode([WatchConversation].self, from: data)

        #expect(decoded.count == 3)

        for (index, watchConv) in decoded.enumerated() {
            #expect(watchConv.title == "Chat \(index + 1)")
        }
    }
}

@Suite("WatchConversation Edge Cases Tests")
struct WatchConversationEdgeCasesTests {
    @Test("Exactly 20 messages")
    func exactlyTwentyMessages() {
        var conversation = Conversation(title: "20 Messages", model: "gpt-4o")

        for idx in 1 ... 20 {
            conversation.addMessage(Message(role: .user, content: "Message \(idx)"))
        }

        let watchConv = WatchConversation(from: conversation)

        #expect(watchConv.messages.count == 20)
        #expect(watchConv.messages.first?.content == "Message 1")
        #expect(watchConv.messages.last?.content == "Message 20")
    }

    @Test("21 messages truncates to 20")
    func twentyOneMessagesTruncatesToTwenty() {
        var conversation = Conversation(title: "21 Messages", model: "gpt-4o")

        for idx in 1 ... 21 {
            conversation.addMessage(Message(role: .user, content: "Message \(idx)"))
        }

        let watchConv = WatchConversation(from: conversation)

        #expect(watchConv.messages.count == 20)
        // Should keep messages 2-21 (last 20)
        #expect(watchConv.messages.first?.content == "Message 2")
        #expect(watchConv.messages.last?.content == "Message 21")
    }

    @Test("Very long message content")
    func veryLongMessageContent() throws {
        let longContent = String(repeating: "A", count: 10000)
        var conversation = Conversation(title: "Long Content", model: "gpt-4o")
        conversation.addMessage(Message(role: .user, content: longContent))

        let watchConv = WatchConversation(from: conversation)

        #expect(watchConv.messages.first?.content.count == 10000)

        // Test Codable with long content
        let data = try JSONEncoder().encode(watchConv)
        let decoded = try JSONDecoder().decode(WatchConversation.self, from: data)

        #expect(decoded.messages.first?.content.count == 10000)
    }

    @Test("Empty title")
    func emptyTitle() {
        let conversation = Conversation(title: "", model: "gpt-4o")
        let watchConv = WatchConversation(from: conversation)

        #expect(watchConv.title.isEmpty)

        let restored = watchConv.toConversation()
        #expect(restored.title.isEmpty)
    }

    @Test("Special characters in title")
    func specialCharactersInTitle() throws {
        let specialTitle = "Chat with émojis 🎉 and \"quotes\""
        let conversation = Conversation(title: specialTitle, model: "gpt-4o")
        let watchConv = WatchConversation(from: conversation)

        #expect(watchConv.title == specialTitle)

        // Test Codable
        let data = try JSONEncoder().encode(watchConv)
        let decoded = try JSONDecoder().decode(WatchConversation.self, from: data)

        #expect(decoded.title == specialTitle)
    }

    @Test("Preserves UUID across round trip")
    func preservesUUIDsAcrossRoundTrip() throws {
        let convId = UUID()
        let msgId = UUID()

        var conversation = Conversation(id: convId, title: "ID Test", model: "gpt-4o")
        let message = Message(id: msgId, role: .user, content: "Test")
        conversation.addMessage(message)

        let watchConv = WatchConversation(from: conversation)

        // Encode and decode
        let data = try JSONEncoder().encode(watchConv)
        let decoded = try JSONDecoder().decode(WatchConversation.self, from: data)

        // Convert back
        let restored = decoded.toConversation()

        #expect(restored.id == convId)
        #expect(restored.messages.first?.id == msgId)
    }

    @Test("Different model names")
    func differentModelNames() {
        let models = ["gpt-4o", "gpt-4-turbo", "gpt-3.5-turbo", "claude-3-opus"]

        for model in models {
            let conversation = Conversation(title: "Test", model: model)
            let watchConv = WatchConversation(from: conversation)

            #expect(watchConv.model == model)
            #expect(watchConv.toConversation().model == model)
        }
    }

    @Test("Multiple message types in conversation")
    func multipleMessageTypesInConversation() {
        var conversation = Conversation(title: "Mixed Types", model: "gpt-4o")

        conversation.addMessage(Message(role: .system, content: "System prompt"))
        conversation.addMessage(Message(role: .user, content: "User message"))
        conversation.addMessage(Message(role: .assistant, content: "Assistant response"))
        conversation.addMessage(Message(role: .tool, content: "Tool output"))

        let watchConv = WatchConversation(from: conversation)
        let restored = watchConv.toConversation()

        #expect(restored.messages.count == 4)
        #expect(restored.messages[0].role == .system)
        #expect(restored.messages[1].role == .user)
        #expect(restored.messages[2].role == .assistant)
        #expect(restored.messages[3].role == .tool)
    }
}

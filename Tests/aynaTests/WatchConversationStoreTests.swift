@testable import Ayna
import XCTest

// Note: WatchConversationStore is only available on watchOS, so these tests verify
// the WatchConversation and WatchMessage data models which are available on all platforms
// for the WatchConnectivityService sync functionality.

@MainActor
final class WatchConversationStoreTests: XCTestCase {
    // MARK: - WatchConversation Tests

    func testWatchConversationInitFromConversation() {
        let conversation = Conversation(
            id: UUID(),
            title: "Test Chat",
            createdAt: Date(),
            model: "gpt-4o"
        )
        var mutableConversation = conversation
        mutableConversation.addMessage(Message(role: .user, content: "Hello"))
        mutableConversation.addMessage(Message(role: .assistant, content: "Hi there!"))

        let watchConversation = WatchConversation(from: mutableConversation)

        XCTAssertEqual(watchConversation.id, mutableConversation.id)
        XCTAssertEqual(watchConversation.title, "Test Chat")
        XCTAssertEqual(watchConversation.model, "gpt-4o")
        XCTAssertEqual(watchConversation.messages.count, 2)
        XCTAssertEqual(watchConversation.messages[0].role, "user")
        XCTAssertEqual(watchConversation.messages[0].content, "Hello")
        XCTAssertEqual(watchConversation.messages[1].role, "assistant")
        XCTAssertEqual(watchConversation.messages[1].content, "Hi there!")
    }

    func testWatchConversationToConversation() {
        let originalId = UUID()
        let createdAt = Date()
        let watchConversation = WatchConversation(
            from: Conversation(id: originalId, title: "Watch Chat", createdAt: createdAt, model: "gpt-4")
        )

        let conversation = watchConversation.toConversation()

        XCTAssertEqual(conversation.id, originalId)
        XCTAssertEqual(conversation.title, "Watch Chat")
        XCTAssertEqual(conversation.model, "gpt-4")
    }

    func testWatchConversationLimitsMessagesToTwenty() {
        var conversation = Conversation(title: "Many Messages", model: "gpt-4o")

        // Add 25 messages
        for index in 1 ... 25 {
            let role: Message.Role = index.isMultiple(of: 2) ? .assistant : .user
            conversation.addMessage(Message(role: role, content: "Message \(index)"))
        }

        let watchConversation = WatchConversation(from: conversation)

        // Should only include the last 20 messages
        XCTAssertEqual(watchConversation.messages.count, 20)
        // First message should be "Message 6" (25-20+1)
        XCTAssertEqual(watchConversation.messages[0].content, "Message 6")
        // Last message should be "Message 25"
        XCTAssertEqual(watchConversation.messages[19].content, "Message 25")
    }

    // MARK: - WatchMessage Tests

    func testWatchMessageInitFromMessage() {
        let messageId = UUID()
        let timestamp = Date()
        let message = Message(
            id: messageId,
            role: .assistant,
            content: "Test response",
            timestamp: timestamp,
            model: "gpt-4o"
        )

        let watchMessage = WatchMessage(from: message)

        XCTAssertEqual(watchMessage.id, messageId)
        XCTAssertEqual(watchMessage.role, "assistant")
        XCTAssertEqual(watchMessage.content, "Test response")
        XCTAssertEqual(watchMessage.timestamp, timestamp)
        XCTAssertEqual(watchMessage.model, "gpt-4o")
    }

    func testWatchMessageToMessage() {
        let messageId = UUID()
        let timestamp = Date()
        let watchMessage = WatchMessage(
            from: Message(
                id: messageId,
                role: .user,
                content: "User question",
                timestamp: timestamp
            )
        )

        let message = watchMessage.toMessage()

        XCTAssertEqual(message.id, messageId)
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.content, "User question")
        XCTAssertEqual(message.timestamp, timestamp)
    }

    func testWatchMessageRoleConversion() {
        let userMessage = WatchMessage(from: Message(role: .user, content: ""))
        let assistantMessage = WatchMessage(from: Message(role: .assistant, content: ""))
        let systemMessage = WatchMessage(from: Message(role: .system, content: ""))
        let toolMessage = WatchMessage(from: Message(role: .tool, content: ""))

        XCTAssertEqual(userMessage.role, "user")
        XCTAssertEqual(assistantMessage.role, "assistant")
        XCTAssertEqual(systemMessage.role, "system")
        XCTAssertEqual(toolMessage.role, "tool")

        XCTAssertEqual(userMessage.toMessage().role, .user)
        XCTAssertEqual(assistantMessage.toMessage().role, .assistant)
        XCTAssertEqual(systemMessage.toMessage().role, .system)
        XCTAssertEqual(toolMessage.toMessage().role, .tool)
    }

    // MARK: - Codable Tests

    func testWatchConversationCodable() throws {
        var conversation = Conversation(title: "Codable Test", model: "gpt-4o")
        conversation.addMessage(Message(role: .user, content: "Test message"))
        let watchConversation = WatchConversation(from: conversation)

        let encoder = JSONEncoder()
        let data = try encoder.encode(watchConversation)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(WatchConversation.self, from: data)

        XCTAssertEqual(decoded.id, watchConversation.id)
        XCTAssertEqual(decoded.title, watchConversation.title)
        XCTAssertEqual(decoded.model, watchConversation.model)
        XCTAssertEqual(decoded.messages.count, 1)
        XCTAssertEqual(decoded.messages[0].content, "Test message")
    }

    func testWatchMessageCodable() throws {
        let message = Message(role: .assistant, content: "Response", model: "gpt-4o")
        let watchMessage = WatchMessage(from: message)

        let encoder = JSONEncoder()
        let data = try encoder.encode(watchMessage)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(WatchMessage.self, from: data)

        XCTAssertEqual(decoded.id, watchMessage.id)
        XCTAssertEqual(decoded.role, "assistant")
        XCTAssertEqual(decoded.content, "Response")
        XCTAssertEqual(decoded.model, "gpt-4o")
    }

    func testWatchConversationArrayCodable() throws {
        var conv1 = Conversation(title: "Chat 1", model: "gpt-4o")
        conv1.addMessage(Message(role: .user, content: "Hello"))

        var conv2 = Conversation(title: "Chat 2", model: "gpt-4")
        conv2.addMessage(Message(role: .user, content: "Hi"))
        conv2.addMessage(Message(role: .assistant, content: "Hello!"))

        let watchConversations = [WatchConversation(from: conv1), WatchConversation(from: conv2)]

        let encoder = JSONEncoder()
        let data = try encoder.encode(watchConversations)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode([WatchConversation].self, from: data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].title, "Chat 1")
        XCTAssertEqual(decoded[0].messages.count, 1)
        XCTAssertEqual(decoded[1].title, "Chat 2")
        XCTAssertEqual(decoded[1].messages.count, 2)
    }

    // MARK: - Edge Cases

    func testWatchConversationWithEmptyMessages() {
        let conversation = Conversation(title: "Empty", model: "gpt-4o")
        let watchConversation = WatchConversation(from: conversation)

        XCTAssertTrue(watchConversation.messages.isEmpty)

        let converted = watchConversation.toConversation()
        XCTAssertTrue(converted.messages.isEmpty)
    }

    func testWatchMessageWithNilModel() {
        let message = Message(role: .user, content: "Question")
        let watchMessage = WatchMessage(from: message)

        XCTAssertNil(watchMessage.model)

        let converted = watchMessage.toMessage()
        XCTAssertNil(converted.model)
    }

    func testWatchConversationStripsAttachments() {
        // Messages with attachments should still convert, but attachments are not
        // preserved in WatchMessage (they're stripped for lightweight sync)
        var conversation = Conversation(title: "With Attachments", model: "gpt-4o")
        let attachment = Message.FileAttachment(
            fileName: "test.txt",
            mimeType: "text/plain",
            data: Data("Hello".utf8),
            localPath: nil
        )
        var message = Message(role: .user, content: "See attached")
        message.attachments = [attachment]
        conversation.addMessage(message)

        let watchConversation = WatchConversation(from: conversation)

        // Message content should be preserved
        XCTAssertEqual(watchConversation.messages.count, 1)
        XCTAssertEqual(watchConversation.messages[0].content, "See attached")

        // WatchMessage doesn't have attachments property - they're stripped
        let converted = watchConversation.messages[0].toMessage()
        XCTAssertNil(converted.attachments)
    }

    // MARK: - Additional Edge Cases

    func testWatchMessageWithEmptyContent() {
        let message = Message(role: .assistant, content: "")
        let watchMessage = WatchMessage(from: message)

        XCTAssertTrue(watchMessage.content.isEmpty)
        XCTAssertTrue(watchMessage.toMessage().content.isEmpty)
    }

    func testWatchMessageWithSpecialCharacters() {
        let content = "Hello 👋 <script>alert('xss')</script> & more \"quotes\""
        let message = Message(role: .user, content: content)
        let watchMessage = WatchMessage(from: message)

        XCTAssertEqual(watchMessage.content, content)
        XCTAssertEqual(watchMessage.toMessage().content, content)
    }

    func testWatchConversationDatePreservation() {
        let createdAt = Date(timeIntervalSince1970: 1_000_000)
        var conversation = Conversation(
            id: UUID(),
            title: "Date Test",
            createdAt: createdAt,
            model: "gpt-4o"
        )
        let updatedAt = Date(timeIntervalSince1970: 2_000_000)
        conversation.updatedAt = updatedAt

        let watchConversation = WatchConversation(from: conversation)

        XCTAssertEqual(watchConversation.createdAt, createdAt)
        XCTAssertEqual(watchConversation.updatedAt, updatedAt)
    }

    func testWatchConversationExactlyTwentyMessages() {
        var conversation = Conversation(title: "Exactly Twenty", model: "gpt-4o")

        // Add exactly 20 messages
        for index in 1 ... 20 {
            conversation.addMessage(Message(role: .user, content: "Message \(index)"))
        }

        let watchConversation = WatchConversation(from: conversation)

        XCTAssertEqual(watchConversation.messages.count, 20)
        XCTAssertEqual(watchConversation.messages.first?.content, "Message 1")
        XCTAssertEqual(watchConversation.messages.last?.content, "Message 20")
    }

    func testWatchConversationLessThanTwentyMessages() {
        var conversation = Conversation(title: "Few Messages", model: "gpt-4o")

        // Add only 5 messages
        for index in 1 ... 5 {
            conversation.addMessage(Message(role: .user, content: "Message \(index)"))
        }

        let watchConversation = WatchConversation(from: conversation)

        XCTAssertEqual(watchConversation.messages.count, 5)
    }

    func testWatchMessageWithLongContent() {
        let longContent = String(repeating: "A", count: 10000)
        let message = Message(role: .assistant, content: longContent)
        let watchMessage = WatchMessage(from: message)

        XCTAssertEqual(watchMessage.content, longContent)
        XCTAssertEqual(watchMessage.toMessage().content, longContent)
    }

    func testWatchConversationIdPreservation() {
        let specificId = UUID()
        let conversation = Conversation(
            id: specificId,
            title: "ID Test",
            createdAt: Date(),
            model: "gpt-4o"
        )

        let watchConversation = WatchConversation(from: conversation)
        let convertedBack = watchConversation.toConversation()

        XCTAssertEqual(watchConversation.id, specificId)
        XCTAssertEqual(convertedBack.id, specificId)
    }

    func testWatchMessageIdPreservation() {
        let specificId = UUID()
        let message = Message(
            id: specificId,
            role: .user,
            content: "Test",
            timestamp: Date()
        )

        let watchMessage = WatchMessage(from: message)
        let convertedBack = watchMessage.toMessage()

        XCTAssertEqual(watchMessage.id, specificId)
        XCTAssertEqual(convertedBack.id, specificId)
    }

    func testWatchConversationWithMixedMessageRoles() {
        var conversation = Conversation(title: "Mixed Roles", model: "gpt-4o")
        conversation.addMessage(Message(role: .system, content: "System prompt"))
        conversation.addMessage(Message(role: .user, content: "User message"))
        conversation.addMessage(Message(role: .assistant, content: "Assistant response"))
        conversation.addMessage(Message(role: .tool, content: "Tool result"))

        let watchConversation = WatchConversation(from: conversation)

        XCTAssertEqual(watchConversation.messages.count, 4)
        XCTAssertEqual(watchConversation.messages[0].role, "system")
        XCTAssertEqual(watchConversation.messages[1].role, "user")
        XCTAssertEqual(watchConversation.messages[2].role, "assistant")
        XCTAssertEqual(watchConversation.messages[3].role, "tool")
    }

    func testWatchConversationTimestampRoundTrip() throws {
        let timestamp = Date()
        var conversation = Conversation(title: "Timestamp Test", model: "gpt-4o")
        conversation.addMessage(Message(role: .user, content: "Test", timestamp: timestamp))

        let watchConversation = WatchConversation(from: conversation)

        // Encode and decode
        let data = try JSONEncoder().encode(watchConversation)
        let decoded = try JSONDecoder().decode(WatchConversation.self, from: data)

        // Timestamp should survive the round trip
        XCTAssertEqual(
            decoded.messages[0].timestamp.timeIntervalSince1970,
            timestamp.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testWatchMessageModelFieldOptional() {
        // Test with model
        let withModel = WatchMessage(from: Message(role: .assistant, content: "Response", model: "gpt-4o"))
        XCTAssertEqual(withModel.model, "gpt-4o")

        // Test without model (nil)
        let withoutModel = WatchMessage(from: Message(role: .user, content: "Question"))
        XCTAssertNil(withoutModel.model)

        // Both should encode/decode correctly
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let dataWithModel = try? encoder.encode(withModel)
        let dataWithoutModel = try? encoder.encode(withoutModel)

        XCTAssertNotNil(dataWithModel)
        XCTAssertNotNil(dataWithoutModel)

        if let data = dataWithModel {
            let decoded = try? decoder.decode(WatchMessage.self, from: data)
            XCTAssertEqual(decoded?.model, "gpt-4o")
        }

        if let data = dataWithoutModel {
            let decoded = try? decoder.decode(WatchMessage.self, from: data)
            XCTAssertNil(decoded?.model)
        }
    }
}

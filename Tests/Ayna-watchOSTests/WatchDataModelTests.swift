//
//  WatchDataModelTests.swift
//  Ayna-watchOSTests
//
//  Unit tests for Watch data models (WatchConversation, WatchMessage)
//  These tests run on watchOS to verify the models work correctly on the target platform
//

@testable import Ayna_watchOS_Watch_App
import XCTest

final class WatchDataModelTests: XCTestCase {
    // MARK: - WatchMessage Tests

    func testWatchMessageInitFromMessage() {
        let originalId = UUID()
        let timestamp = Date()
        let message = Message(
            id: originalId,
            role: .user,
            content: "Test content",
            timestamp: timestamp,
            model: "gpt-4o"
        )

        let watchMessage = WatchMessage(from: message)

        XCTAssertEqual(watchMessage.id, originalId)
        XCTAssertEqual(watchMessage.role, "user")
        XCTAssertEqual(watchMessage.content, "Test content")
        XCTAssertEqual(watchMessage.timestamp, timestamp)
        XCTAssertEqual(watchMessage.model, "gpt-4o")
    }

    func testWatchMessageToMessage() {
        let originalId = UUID()
        let timestamp = Date()
        let watchMessage = WatchMessage(
            from: Message(
                id: originalId,
                role: .assistant,
                content: "Response",
                timestamp: timestamp,
                model: "gpt-4"
            )
        )

        let message = watchMessage.toMessage()

        XCTAssertEqual(message.id, originalId)
        XCTAssertEqual(message.role, .assistant)
        XCTAssertEqual(message.content, "Response")
        XCTAssertEqual(message.timestamp, timestamp)
        XCTAssertEqual(message.model, "gpt-4")
    }

    func testWatchMessageAllRoles() {
        let roles: [Message.Role] = [.user, .assistant, .system, .tool]

        for role in roles {
            let message = Message(role: role, content: "Test")
            let watchMessage = WatchMessage(from: message)

            XCTAssertEqual(watchMessage.role, role.rawValue)
            XCTAssertEqual(watchMessage.toMessage().role, role)
        }
    }

    func testWatchMessageWithoutModel() {
        let message = Message(role: .user, content: "Question")
        let watchMessage = WatchMessage(from: message)

        XCTAssertNil(watchMessage.model)
        XCTAssertNil(watchMessage.toMessage().model)
    }

    func testWatchMessageCodable() throws {
        let message = Message(role: .assistant, content: "Test", model: "gpt-4o")
        let watchMessage = WatchMessage(from: message)

        let encoder = JSONEncoder()
        let data = try encoder.encode(watchMessage)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(WatchMessage.self, from: data)

        XCTAssertEqual(decoded.id, watchMessage.id)
        XCTAssertEqual(decoded.role, watchMessage.role)
        XCTAssertEqual(decoded.content, watchMessage.content)
        XCTAssertEqual(decoded.model, watchMessage.model)
    }

    // MARK: - WatchConversation Tests

    func testWatchConversationInitFromConversation() {
        let originalId = UUID()
        let createdAt = Date()
        var conversation = Conversation(
            id: originalId,
            title: "Test Chat",
            createdAt: createdAt,
            model: "gpt-4o"
        )
        conversation.addMessage(Message(role: .user, content: "Hello"))
        conversation.addMessage(Message(role: .assistant, content: "Hi!"))

        let watchConversation = WatchConversation(from: conversation)

        XCTAssertEqual(watchConversation.id, originalId)
        XCTAssertEqual(watchConversation.title, "Test Chat")
        XCTAssertEqual(watchConversation.model, "gpt-4o")
        XCTAssertEqual(watchConversation.messages.count, 2)
    }

    func testWatchConversationToConversation() {
        let originalId = UUID()
        let conversation = Conversation(id: originalId, title: "Watch Chat", model: "gpt-4")
        let watchConversation = WatchConversation(from: conversation)

        let converted = watchConversation.toConversation()

        XCTAssertEqual(converted.id, originalId)
        XCTAssertEqual(converted.title, "Watch Chat")
        XCTAssertEqual(converted.model, "gpt-4")
    }

    func testWatchConversationLimitsMessages() {
        var conversation = Conversation(title: "Many Messages", model: "gpt-4o")

        // Add more than 20 messages
        for index in 1 ... 30 {
            let role: Message.Role = index.isMultiple(of: 2) ? .assistant : .user
            conversation.addMessage(Message(role: role, content: "Message \(index)"))
        }

        let watchConversation = WatchConversation(from: conversation)

        // Should only include the last 20
        XCTAssertEqual(watchConversation.messages.count, 20)
        // First message should be "Message 11" (30-20+1)
        XCTAssertEqual(watchConversation.messages.first?.content, "Message 11")
        // Last message should be "Message 30"
        XCTAssertEqual(watchConversation.messages.last?.content, "Message 30")
    }

    func testWatchConversationCodable() throws {
        var conversation = Conversation(title: "Codable Test", model: "gpt-4o")
        conversation.addMessage(Message(role: .user, content: "Test"))
        let watchConversation = WatchConversation(from: conversation)

        let encoder = JSONEncoder()
        let data = try encoder.encode(watchConversation)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(WatchConversation.self, from: data)

        XCTAssertEqual(decoded.id, watchConversation.id)
        XCTAssertEqual(decoded.title, watchConversation.title)
        XCTAssertEqual(decoded.model, watchConversation.model)
        XCTAssertEqual(decoded.messages.count, 1)
    }

    func testWatchConversationArrayCodable() throws {
        var conv1 = Conversation(title: "Chat 1", model: "gpt-4o")
        conv1.addMessage(Message(role: .user, content: "Hello"))

        var conv2 = Conversation(title: "Chat 2", model: "gpt-4")
        conv2.addMessage(Message(role: .user, content: "Hi"))

        let watchConversations = [
            WatchConversation(from: conv1),
            WatchConversation(from: conv2)
        ]

        let encoder = JSONEncoder()
        let data = try encoder.encode(watchConversations)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode([WatchConversation].self, from: data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].title, "Chat 1")
        XCTAssertEqual(decoded[1].title, "Chat 2")
    }

    // MARK: - Edge Cases

    func testEmptyConversation() {
        let conversation = Conversation(title: "Empty", model: "gpt-4o")
        let watchConversation = WatchConversation(from: conversation)

        XCTAssertTrue(watchConversation.messages.isEmpty)

        let converted = watchConversation.toConversation()
        XCTAssertTrue(converted.messages.isEmpty)
    }

    func testMessageWithEmptyContent() {
        let message = Message(role: .assistant, content: "")
        let watchMessage = WatchMessage(from: message)

        XCTAssertTrue(watchMessage.content.isEmpty)
        XCTAssertTrue(watchMessage.toMessage().content.isEmpty)
    }

    func testMessageWithSpecialCharacters() {
        let content = "Hello 👋 <script>alert('xss')</script> & more"
        let message = Message(role: .user, content: content)
        let watchMessage = WatchMessage(from: message)

        XCTAssertEqual(watchMessage.content, content)
        XCTAssertEqual(watchMessage.toMessage().content, content)
    }

    func testConversationDatePreservation() {
        let createdAt = Date(timeIntervalSince1970: 1_000_000)
        let updatedAt = Date(timeIntervalSince1970: 2_000_000)

        var conversation = Conversation(
            id: UUID(),
            title: "Date Test",
            createdAt: createdAt,
            model: "gpt-4o"
        )
        conversation.updatedAt = updatedAt

        let watchConversation = WatchConversation(from: conversation)

        XCTAssertEqual(watchConversation.createdAt, createdAt)
        XCTAssertEqual(watchConversation.updatedAt, updatedAt)
    }
}

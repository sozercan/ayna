//
//  WatchDataModelTests.swift
//  Ayna-watchOSTests
//
//  Unit tests for Watch data models (WatchConversation, WatchMessage)
//  These tests run on watchOS to verify the models work correctly on the target platform
//

@testable import Ayna_watchOS_Watch_App
import Foundation
import Testing

@Suite("WatchDataModel Tests")
struct WatchDataModelTests {
    // MARK: - WatchMessage Tests

    @Test("WatchMessage init from Message")
    func watchMessageInitFromMessage() {
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

        #expect(watchMessage.id == originalId)
        #expect(watchMessage.role == "user")
        #expect(watchMessage.content == "Test content")
        #expect(watchMessage.timestamp == timestamp)
        #expect(watchMessage.model == "gpt-4o")
    }

    @Test("WatchMessage to Message")
    func watchMessageToMessage() {
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

        #expect(message.id == originalId)
        #expect(message.role == .assistant)
        #expect(message.content == "Response")
        #expect(message.timestamp == timestamp)
        #expect(message.model == "gpt-4")
    }

    @Test("WatchMessage all roles")
    func watchMessageAllRoles() {
        let roles: [Message.Role] = [.user, .assistant, .system, .tool]

        for role in roles {
            let message = Message(role: role, content: "Test")
            let watchMessage = WatchMessage(from: message)

            #expect(watchMessage.role == role.rawValue)
            #expect(watchMessage.toMessage().role == role)
        }
    }

    @Test("WatchMessage without model")
    func watchMessageWithoutModel() {
        let message = Message(role: .user, content: "Question")
        let watchMessage = WatchMessage(from: message)

        #expect(watchMessage.model == nil)
        #expect(watchMessage.toMessage().model == nil)
    }

    @Test("WatchMessage Codable")
    func watchMessageCodable() throws {
        let message = Message(role: .assistant, content: "Test", model: "gpt-4o")
        let watchMessage = WatchMessage(from: message)

        let encoder = JSONEncoder()
        let data = try encoder.encode(watchMessage)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(WatchMessage.self, from: data)

        #expect(decoded.id == watchMessage.id)
        #expect(decoded.role == watchMessage.role)
        #expect(decoded.content == watchMessage.content)
        #expect(decoded.model == watchMessage.model)
    }

    // MARK: - WatchConversation Tests

    @Test("WatchConversation init from Conversation")
    func watchConversationInitFromConversation() {
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

        #expect(watchConversation.id == originalId)
        #expect(watchConversation.title == "Test Chat")
        #expect(watchConversation.model == "gpt-4o")
        #expect(watchConversation.messages.count == 2)
    }

    @Test("WatchConversation to Conversation")
    func watchConversationToConversation() {
        let originalId = UUID()
        let conversation = Conversation(id: originalId, title: "Watch Chat", model: "gpt-4")
        let watchConversation = WatchConversation(from: conversation)

        let converted = watchConversation.toConversation()

        #expect(converted.id == originalId)
        #expect(converted.title == "Watch Chat")
        #expect(converted.model == "gpt-4")
    }

    @Test("WatchConversation limits messages to 20")
    func watchConversationLimitsMessages() {
        var conversation = Conversation(title: "Many Messages", model: "gpt-4o")

        // Add more than 20 messages
        for index in 1 ... 30 {
            let role: Message.Role = index.isMultiple(of: 2) ? .assistant : .user
            conversation.addMessage(Message(role: role, content: "Message \(index)"))
        }

        let watchConversation = WatchConversation(from: conversation)

        // Should only include the last 20
        #expect(watchConversation.messages.count == 20)
        // First message should be "Message 11" (30-20+1)
        #expect(watchConversation.messages.first?.content == "Message 11")
        // Last message should be "Message 30"
        #expect(watchConversation.messages.last?.content == "Message 30")
    }

    @Test("WatchConversation Codable")
    func watchConversationCodable() throws {
        var conversation = Conversation(title: "Codable Test", model: "gpt-4o")
        conversation.addMessage(Message(role: .user, content: "Test"))
        let watchConversation = WatchConversation(from: conversation)

        let encoder = JSONEncoder()
        let data = try encoder.encode(watchConversation)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(WatchConversation.self, from: data)

        #expect(decoded.id == watchConversation.id)
        #expect(decoded.title == watchConversation.title)
        #expect(decoded.model == watchConversation.model)
        #expect(decoded.messages.count == 1)
    }

    @Test("WatchConversation array Codable")
    func watchConversationArrayCodable() throws {
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

        #expect(decoded.count == 2)
        #expect(decoded[0].title == "Chat 1")
        #expect(decoded[1].title == "Chat 2")
    }

    // MARK: - Edge Cases

    @Test("Empty conversation")
    func emptyConversation() {
        let conversation = Conversation(title: "Empty", model: "gpt-4o")
        let watchConversation = WatchConversation(from: conversation)

        #expect(watchConversation.messages.isEmpty)

        let converted = watchConversation.toConversation()
        #expect(converted.messages.isEmpty)
    }

    @Test("Message with empty content")
    func messageWithEmptyContent() {
        let message = Message(role: .assistant, content: "")
        let watchMessage = WatchMessage(from: message)

        #expect(watchMessage.content.isEmpty)
        #expect(watchMessage.toMessage().content.isEmpty)
    }

    @Test("Message with special characters")
    func messageWithSpecialCharacters() {
        let content = "Hello 👋 <script>alert('xss')</script> & more"
        let message = Message(role: .user, content: content)
        let watchMessage = WatchMessage(from: message)

        #expect(watchMessage.content == content)
        #expect(watchMessage.toMessage().content == content)
    }

    @Test("Conversation date preservation")
    func conversationDatePreservation() {
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

        #expect(watchConversation.createdAt == createdAt)
        #expect(watchConversation.updatedAt == updatedAt)
    }
}

// swiftlint:disable identifier_name
@testable import Ayna
import Foundation
import Testing

@Suite("Watch data model host tests", .tags(.fast))
struct WatchDataModelHostTests {
    @Test
    func `Watch message round trips stable identity and metadata`() throws {
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 100)
        let call = MCPToolCall(
            id: "call",
            toolName: "lookup",
            arguments: ["query": AnyCodable("weather")],
            result: "sunny",
            timestamp: timestamp
        )
        let original = Message(
            id: id,
            role: .assistant,
            content: "Result",
            timestamp: timestamp,
            toolCalls: [call],
            model: "gpt-test",
            citations: [CitationReference(number: 1, title: "Source", url: "https://example.com")]
        )

        let encoded = try JSONEncoder().encode(WatchMessage(from: original))
        let decoded = try JSONDecoder().decode(WatchMessage.self, from: encoded)
        let restored = decoded.toMessage()

        #expect(restored.id == id)
        #expect(restored.role == .assistant)
        #expect(restored.content == "Result")
        #expect(restored.timestamp == timestamp)
        #expect(restored.model == "gpt-test")
        #expect(restored.toolCalls == [call])
        #expect(restored.citations == original.citations)
    }

    @Test
    func `Compact request configuration round trips and clears a retained prompt without touching messages`() throws {
        let conversationID = UUID()
        let retainedMessage = WatchMessage(from: Message(role: .user, content: "Keep me"))
        var conversation = WatchConversation(
            id: conversationID,
            title: "Retained",
            messages: [retainedMessage],
            model: "old-model",
            updatedAt: Date(timeIntervalSince1970: 2),
            createdAt: Date(timeIntervalSince1970: 1),
            temperature: 1.0,
            resolvedSystemPrompt: "Old prompt"
        )
        let original = WatchConversationRequestConfiguration(
            id: conversationID,
            model: "new-model",
            temperature: 0.3,
            resolvedSystemPrompt: nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            WatchConversationRequestConfiguration.self,
            from: data
        )
        decoded.apply(to: &conversation)

        #expect(decoded == original)
        #expect(conversation.model == "new-model")
        #expect(conversation.temperature == 0.3)
        #expect(conversation.resolvedSystemPrompt == nil)
        #expect(conversation.messages == [retainedMessage])
    }

    @Test
    func `Long custom model identifiers preserve settings key identity across data model Codable`() throws {
        let maximumModelCharacters = WatchSyncPayloadConfiguration.default.maximumModelCharacters
        let model = "custom-provider/" + String(repeating: "data-model-segment-", count: 12)
        #expect(model.count > maximumModelCharacters)
        let message = WatchMessage(
            id: UUID(),
            role: Message.Role.assistant.rawValue,
            content: "Response",
            timestamp: Date(timeIntervalSince1970: 2),
            model: model
        )
        let conversation = WatchConversation(
            id: UUID(),
            title: "Long model",
            messages: [message],
            model: model,
            updatedAt: Date(timeIntervalSince1970: 2),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let compactConfiguration = WatchConversationRequestConfiguration(
            id: conversation.id,
            model: model,
            temperature: 0.4,
            resolvedSystemPrompt: "Prompt"
        )

        let decodedConversation = try JSONDecoder().decode(
            WatchConversation.self,
            from: JSONEncoder().encode(conversation)
        )
        let decodedConfiguration = try JSONDecoder().decode(
            WatchConversationRequestConfiguration.self,
            from: JSONEncoder().encode(compactConfiguration)
        )
        var applied = conversation
        applied.model = "old-model"
        decodedConfiguration.apply(to: &applied)
        let settingsByModel = [model: "exact-settings"]

        #expect(decodedConversation.model == model)
        #expect(decodedConversation.messages.first?.model == model)
        #expect(decodedConversation.toConversation().model == model)
        #expect(decodedConfiguration.model == model)
        #expect(applied.model == model)
        #expect(settingsByModel[decodedConversation.model] == "exact-settings")
        #expect(settingsByModel[decodedConfiguration.model] == "exact-settings")
    }

    @Test
    func `Conversation conversion carries temperature prompt revision and effective history`() {
        let groupID = UUID()
        let userID = UUID()
        let rejectedID = UUID()
        let selectedID = UUID()
        let timestamp = Date(timeIntervalSince1970: 200)
        let user = Message(id: userID, role: .user, content: "Question", timestamp: timestamp)
        let rejected = Message(
            id: rejectedID,
            role: .assistant,
            content: "Rejected",
            timestamp: timestamp.addingTimeInterval(1),
            model: "other",
            responseGroupId: groupID,
            isSelectedResponse: false
        )
        let selected = Message(
            id: selectedID,
            role: .assistant,
            content: "Selected",
            timestamp: timestamp.addingTimeInterval(2),
            model: "chosen",
            responseGroupId: groupID,
            isSelectedResponse: true
        )
        let group = ResponseGroup(
            id: groupID,
            userMessageId: userID,
            responses: [
                ResponseGroupEntry(id: rejectedID, modelName: "other", status: .completed),
                ResponseGroupEntry(id: selectedID, modelName: "chosen", status: .selected)
            ],
            selectedResponseId: selectedID,
            createdAt: timestamp
        )
        var conversation = Conversation(
            title: "Effective",
            messages: [user, rejected, selected],
            createdAt: timestamp,
            updatedAt: timestamp.addingTimeInterval(3),
            model: "chosen",
            systemPromptMode: .custom("Be precise"),
            temperature: 0.25,
            responseGroups: [group]
        )

        let watch = WatchConversation(
            from: conversation,
            resolvedSystemPrompt: "Be precise",
            watchRevision: 7
        )

        #expect(watch.temperature == 0.25)
        #expect(watch.resolvedSystemPrompt == "Be precise")
        #expect(watch.watchRevision == 7)
        #expect(watch.messages.map(\.id) == [userID, selectedID])
        #expect(watch.effectiveHistory.map(\.role) == [.system, .user, .assistant])
        #expect(watch.effectiveHistory.first?.content == "Be precise")

        conversation.pendingAutoSendPrompt = "phone-only"
        let restored = watch.toConversation()
        #expect(restored.temperature == 0.25)
        #expect(restored.systemPromptMode == .inheritGlobal)
        #expect(restored.messages.map(\.id) == [userID, selectedID])
    }

    @Test
    func `Conversation conversion preserves a failed partial response fallback`() {
        let groupID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1000)
        let user = Message(role: .user, content: "Question", timestamp: timestamp)
        let failed = Message(
            role: .assistant,
            content: "Saved partial",
            timestamp: timestamp.addingTimeInterval(1),
            model: "model-a",
            responseGroupId: groupID
        )
        let group = ResponseGroup(
            id: groupID,
            userMessageId: user.id,
            responses: [
                ResponseGroupEntry(id: failed.id, modelName: "model-a", status: .failed)
            ],
            createdAt: timestamp
        )
        let conversation = Conversation(
            messages: [user, failed],
            createdAt: timestamp,
            updatedAt: timestamp.addingTimeInterval(2),
            model: "model-a",
            responseGroups: [group]
        )

        let watch = WatchConversation(from: conversation)

        #expect(watch.messages.map(\.id) == [user.id, failed.id])
        #expect(watch.effectiveHistory.last?.content == "Saved partial")
    }

    @Test
    func `Conversation conversion keeps only the newest bounded messages`() {
        let base = Date(timeIntervalSince1970: 1000)
        let messages = (0 ..< 30).map { index in
            Message(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "message-\(index)",
                timestamp: base.addingTimeInterval(Double(index))
            )
        }
        let conversation = Conversation(title: "Long", messages: messages, model: "model")

        let watch = WatchConversation(from: conversation, maximumMessages: 20)

        #expect(watch.messages.count == 20)
        #expect(watch.messages.first?.content == "message-10")
        #expect(watch.messages.last?.content == "message-29")
    }

    @Test
    func `Legacy WatchConversation payload decodes new fields with safe defaults`() throws {
        let legacy = LegacyWatchConversation(
            id: UUID(),
            title: "Legacy",
            messages: [],
            model: "legacy-model",
            updatedAt: Date(timeIntervalSince1970: 20),
            createdAt: Date(timeIntervalSince1970: 10)
        )

        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(WatchConversation.self, from: data)

        #expect(decoded.temperature == 0.7)
        #expect(decoded.resolvedSystemPrompt == nil)
        #expect(decoded.watchRevision == 0)
        #expect(decoded.title == "Legacy")
    }

    @Test
    func `WatchConversation Codable preserves new fields`() throws {
        let original = WatchConversation(
            id: UUID(),
            title: "Codable",
            messages: [WatchMessage(from: Message(role: .user, content: "Hello"))],
            model: "model",
            updatedAt: Date(timeIntervalSince1970: 30),
            createdAt: Date(timeIntervalSince1970: 10),
            temperature: 1.1,
            resolvedSystemPrompt: "Prompt",
            watchRevision: 42
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WatchConversation.self, from: data)

        #expect(decoded == original)
    }

    @Test
    func `Snapshot construction and decoding canonicalize duplicate conversation IDs`() throws {
        let conversationID = UUID()
        let newerTimestamp = WatchConversation(
            id: conversationID,
            title: "Newer timestamp",
            model: "timestamp-model",
            updatedAt: Date(timeIntervalSince1970: 40),
            createdAt: Date(timeIntervalSince1970: 1),
            watchRevision: 4
        )
        let newerRevision = WatchConversation(
            id: conversationID,
            title: "Newer revision",
            model: "revision-model",
            updatedAt: Date(timeIntervalSince1970: 20),
            createdAt: Date(timeIntervalSince1970: 1),
            watchRevision: 5
        )

        let constructed = WatchSyncSnapshot(
            revision: 1,
            conversations: [newerTimestamp, newerRevision],
            authoritativeConversationIDs: [conversationID, conversationID]
        )
        let encoded = try JSONEncoder().encode(DuplicateConversationSnapshotPayload(
            sourceID: constructed.sourceID,
            revision: constructed.revision,
            conversations: [newerTimestamp, newerRevision],
            authoritativeConversationIDs: [conversationID, conversationID]
        ))
        let decoded = try JSONDecoder().decode(WatchSyncSnapshot.self, from: encoded)

        for snapshot in [constructed, decoded] {
            #expect(snapshot.conversations.count == 1)
            #expect(snapshot.conversations.first?.title == "Newer revision")
            #expect(snapshot.conversations.first?.watchRevision == 5)
            #expect(snapshot.authoritativeConversationIDs == [conversationID])
        }
    }

    @Test
    func `Explicit null snapshot schema is rejected instead of defaulting to legacy version one`() throws {
        let snapshot = WatchSyncSnapshot(
            revision: 1,
            conversations: [],
            authoritativeConversationIDs: []
        )
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["schemaVersion"] = NSNull()
        let malformed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(WatchSyncSnapshot.self, from: malformed)
        }
    }
}

private struct DuplicateConversationSnapshotPayload: Encodable {
    let schemaVersion = WatchSyncSnapshot.currentSchemaVersion
    let sourceID: UUID
    let revision: WatchSyncRevision
    let conversations: [WatchConversation]
    let authoritativeConversationIDs: [UUID]
    let authoritativeConversationIDsAreComplete = true
}

private struct LegacyWatchConversation: Codable {
    let id: UUID
    let title: String
    let messages: [WatchMessage]
    let model: String
    let updatedAt: Date
    let createdAt: Date
}

// swiftlint:enable identifier_name

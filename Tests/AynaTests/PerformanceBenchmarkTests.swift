@testable import Ayna
import Foundation
import Testing

@Suite("Parser Performance Benchmarks", .tags(.slow), .serialized)
struct ParserPerformanceBenchmarkTests {
    private static let lineCount = 10000

    @Test("OpenAI parser processes 10k content SSE string lines", .timeLimit(.minutes(1)))
    func openAIParserProcesses10kContentSSEStringLines() async {
        let line = #"data: {"choices":[{"delta":{"content":"x"}}]}"#
        var buffers: [Int: [String: Any]] = [:]
        var ids: [Int: String] = [:]
        var contentLength = 0

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0 ..< Self.lineCount {
            let result = await OpenAIStreamParser.processStreamLine(
                line,
                toolCallBuffers: buffers,
                toolCallIds: ids,
                onToolCall: nil,
                onToolCallRequested: nil
            )
            buffers = result.toolCallBuffers
            ids = result.toolCallIds
            contentLength += result.content?.count ?? 0
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        print("BENCH parser.openai.string.10k seconds=\(elapsed)")
        #expect(contentLength == Self.lineCount)
    }

    @Test("OpenAI parser processes 10k content SSE data lines", .timeLimit(.minutes(1)))
    func openAIParserProcesses10kContentSSEDataLines() async {
        let line = Data(#"data: {"choices":[{"delta":{"content":"x"}}]}"#.utf8)
        var buffers: [Int: [String: Any]] = [:]
        var ids: [Int: String] = [:]
        var contentLength = 0

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0 ..< Self.lineCount {
            let result = await OpenAIStreamParser.processStreamLine(
                line,
                toolCallBuffers: buffers,
                toolCallIds: ids,
                onToolCall: nil,
                onToolCallRequested: nil
            )
            buffers = result.toolCallBuffers
            ids = result.toolCallIds
            contentLength += result.content?.count ?? 0
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        print("BENCH parser.openai.data.10k seconds=\(elapsed)")
        #expect(contentLength == Self.lineCount)
    }

    @Test("Anthropic parser processes 10k content SSE string lines", .timeLimit(.minutes(1)))
    func anthropicParserProcesses10kContentSSEStringLines() {
        let parser = AnthropicStreamParser()
        _ = parser.processLine(#"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x"}}"#
        var contentLength = 0

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0 ..< Self.lineCount {
            let result = parser.processLine(line)
            contentLength += result.content?.count ?? 0
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        print("BENCH parser.anthropic.string.10k seconds=\(elapsed)")
        #expect(contentLength == Self.lineCount)
    }

    @Test("Anthropic parser processes 10k content SSE data lines", .timeLimit(.minutes(1)))
    func anthropicParserProcesses10kContentSSEDataLines() {
        let parser = AnthropicStreamParser()
        _ = parser.processLine(Data(#"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#.utf8))
        let line = Data(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x"}}"#.utf8)
        var contentLength = 0

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0 ..< Self.lineCount {
            let result = parser.processLine(line)
            contentLength += result.content?.count ?? 0
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        print("BENCH parser.anthropic.data.10k seconds=\(elapsed)")
        #expect(contentLength == Self.lineCount)
    }
}

@Suite("Persistence Cold-Load Benchmarks", .tags(.persistence, .slow), .serialized)
struct PersistenceColdLoadBenchmarkTests {
    private static let conversationCount = 180
    private static let messagesPerConversation = 50
    private static let messagePayloadBytes = 4096

    private struct Fixture {
        let directory: URL
        let keyIdentifier: String
        let keychain: InMemoryKeychainStorage
    }

    @Test("Encrypted store loads many full conversations", .timeLimit(.minutes(1)))
    func encryptedStoreLoadsManyFullConversations() async throws {
        let fixture = try await Self.makeFixture()
        let coldStore = TestHelpers.makeTestStore(
            directory: fixture.directory,
            keyIdentifier: fixture.keyIdentifier,
            keychain: fixture.keychain
        )

        let start = CFAbsoluteTimeGetCurrent()
        let loaded = try await coldStore.loadConversations()
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        print(
            "BENCH persistence.conversations.fullLoad.\(Self.conversationCount)x\(Self.messagesPerConversation) seconds=\(elapsed)"
        )
        #expect(loaded.count == Self.conversationCount)
        #expect(loaded.reduce(0) { $0 + $1.messages.count } == Self.conversationCount * Self.messagesPerConversation)
    }

    @Test("Encrypted store loads many conversation metadata sidecars", .timeLimit(.minutes(1)))
    func encryptedStoreLoadsManyConversationMetadataSidecars() async throws {
        let fixture = try await Self.makeFixture()
        let coldStore = TestHelpers.makeTestStore(
            directory: fixture.directory,
            keyIdentifier: fixture.keyIdentifier,
            keychain: fixture.keychain
        )

        let start = CFAbsoluteTimeGetCurrent()
        let metadata = try await coldStore.loadConversationMetadata()
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        print(
            "BENCH persistence.conversations.metadataLoad.\(Self.conversationCount)x\(Self.messagesPerConversation) seconds=\(elapsed)"
        )
        #expect(metadata.count == Self.conversationCount)
        #expect(metadata.reduce(0) { $0 + $1.messageCount } == Self.conversationCount * Self.messagesPerConversation)
    }

    private static func makeFixture() async throws -> Fixture {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keyIdentifier = UUID().uuidString
        let keychain = InMemoryKeychainStorage()
        let store = TestHelpers.makeTestStore(
            directory: directory,
            keyIdentifier: keyIdentifier,
            keychain: keychain
        )

        for conversation in Self.benchmarkConversations() {
            try await store.save(conversation)
        }

        return Fixture(directory: directory, keyIdentifier: keyIdentifier, keychain: keychain)
    }

    private static func benchmarkConversations() -> [Conversation] {
        (0 ..< conversationCount).map { index in
            let updatedAt = Date(timeIntervalSinceReferenceDate: 1_700_000_000 + Double(index))
            let payload = String(repeating: "x", count: messagePayloadBytes)
            let messages = (0 ..< messagesPerConversation).map { messageIndex in
                Message(
                    role: messageIndex.isMultiple(of: 2) ? .user : .assistant,
                    content: "conversation=\(index) message=\(messageIndex) \(payload)",
                    timestamp: updatedAt.addingTimeInterval(Double(messageIndex))
                )
            }

            return Conversation(
                title: "Benchmark Conversation \(index)",
                messages: messages,
                createdAt: updatedAt.addingTimeInterval(-3600),
                updatedAt: updatedAt,
                model: "gpt-4o"
            )
        }
    }
}

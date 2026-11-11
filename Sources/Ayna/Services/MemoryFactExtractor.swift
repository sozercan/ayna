//
//  MemoryFactExtractor.swift
//  Ayna
//
//  Opt-in extraction of durable facts about the user from their conversations.
//

import Foundation

/// Reads what the user said in a conversation once it goes quiet and stores durable facts
/// about them (preferences, background, ongoing projects) as inferred memory.
///
/// Apple Intelligence is used when it is available, so nothing leaves the device; otherwise the
/// conversation's own model, which already received these messages, does the extraction.
@MainActor
final class MemoryFactExtractor {
    typealias Generate = @MainActor (_ prompt: String, _ conversationModel: String) async throws -> String

    static let shared = MemoryFactExtractor()

    /// Quiet period after the last save before a conversation is examined.
    static let defaultIdleDelay: Duration = .seconds(60)
    static let maximumFactsPerPass = 3
    static let maximumFactLength = 200
    private static let maximumPromptCharacters = 3000

    private let idleDelay: Duration
    private let generate: Generate
    private let existingFacts: @MainActor () -> [UserMemoryFact]
    private let storeFact: @MainActor (String) -> Void
    private var idleTasks: [UUID: Task<Void, Never>] = [:]
    /// User messages already examined, per conversation, so each is read once per launch.
    private var examinedMessageIDs: [UUID: Set<UUID>] = [:]

    init(
        idleDelay: Duration = MemoryFactExtractor.defaultIdleDelay,
        generate: Generate? = nil,
        existingFacts: (@MainActor () -> [UserMemoryFact])? = nil,
        storeFact: (@MainActor (String) -> Void)? = nil
    ) {
        self.idleDelay = idleDelay
        self.generate = generate ?? Self.defaultGenerate
        self.existingFacts = existingFacts ?? { UserMemoryService.shared.activeFacts() }
        self.storeFact = storeFact ?? { _ = UserMemoryService.shared.addFact($0, source: .inferred) }
    }

    /// Restarts the quiet-period timer for a conversation that was just saved.
    func conversationDidSave(_ conversation: Conversation) {
        idleTasks[conversation.id]?.cancel()
        let idleDelay = idleDelay
        idleTasks[conversation.id] = Task { [weak self] in
            do {
                try await Task.sleep(for: idleDelay)
            } catch {
                return
            }
            await self?.extract(from: conversation)
            // A replacement timer may already sit in this slot; only the current task clears it.
            guard !Task.isCancelled else { return }
            self?.idleTasks[conversation.id] = nil
        }
    }

    func cancel(conversationId: UUID) {
        idleTasks.removeValue(forKey: conversationId)?.cancel()
        examinedMessageIDs.removeValue(forKey: conversationId)
    }

    func cancelAll() {
        idleTasks.values.forEach { $0.cancel() }
        idleTasks.removeAll()
    }

    /// Examines the conversation's not-yet-examined user messages and stores new facts.
    func extract(from conversation: Conversation) async {
        guard AIService.shared.getModelCapability(conversation.model) != .imageGeneration else { return }
        let examined = examinedMessageIDs[conversation.id, default: []]
        let newMessages = conversation.messages.filter { message in
            message.role == .user && !examined.contains(message.id)
                && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !newMessages.isEmpty else { return }

        let request = Self.prompt(userMessages: newMessages, existingFacts: existingFacts().map(\.content))
        let response: String
        do {
            response = try await generate(request.prompt, conversation.model)
        } catch is CancellationError {
            return
        } catch {
            DiagnosticsLogger.log(
                .conversationManager,
                level: .error,
                message: "Memory fact extraction failed",
                metadata: ["error": error.localizedDescription]
            )
            return
        }
        // Cancelled while generating (conversation deleted, memory cleared, extraction off).
        guard !Task.isCancelled else { return }
        // Only messages that made it into the prompt count as read; the rest go in a later pass.
        examinedMessageIDs[conversation.id, default: []].formUnion(request.includedMessageIDs)

        // Facts may have changed while the model was answering (another pass, manual edits).
        let known = existingFacts().map(\.content)
        var stored: [String] = []
        for fact in Self.parseFacts(response) where !Self.isDuplicate(fact, of: known + stored) {
            storeFact(fact)
            stored.append(fact)
        }
        if !stored.isEmpty {
            DiagnosticsLogger.log(
                .conversationManager,
                level: .info,
                message: "Stored inferred memory facts",
                metadata: ["count": "\(stored.count)"]
            )
        }
    }

    // MARK: - Prompt and parsing

    static let instructions = """
    You extract durable facts about a user from messages they wrote to an assistant. \
    A durable fact stays true for months: their name, job, location, tools they use, lasting \
    preferences, ongoing projects. Ignore one-off requests, questions, and anything about other \
    people. Never include secrets such as passwords, keys, or financial or health details.
    """

    /// Builds the prompt from the newest messages that fit, truncating one that alone is too long.
    static func prompt(
        userMessages: [Message],
        existingFacts: [String]
    ) -> (prompt: String, includedMessageIDs: [UUID]) {
        var messages = ""
        var included: [UUID] = []
        for message in userMessages.reversed() {
            var text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if included.isEmpty, text.count > maximumPromptCharacters - 3 {
                text = String(text.prefix(maximumPromptCharacters - 3))
            }
            let entry = "- \(text)\n"
            guard messages.count + entry.count <= maximumPromptCharacters else { break }
            messages = entry + messages
            included.append(message.id)
        }
        let known = existingFacts.isEmpty ? "(none)" : existingFacts.map { "- \($0)" }.joined(separator: "\n")
        let prompt = """
        \(instructions)

        Already known (do not repeat):
        \(known)

        Messages from the user:
        \(messages)
        Reply with a JSON array of at most \(maximumFactsPerPass) short facts written in the third \
        person, for example ["Works as a nurse", "Prefers metric units"]. Reply with [] if there are none.
        """
        return (prompt, included)
    }

    /// Reads the JSON array from a reply, tolerating surrounding text or a code fence.
    static func parseFacts(_ response: String) -> [String] {
        guard let start = response.firstIndex(of: "["),
              let end = response.lastIndex(of: "]"),
              start < end,
              let data = String(response[start ... end]).data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else {
            return []
        }
        return values
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= maximumFactLength }
            .prefix(maximumFactsPerPass)
            .map { $0 }
    }

    static func isDuplicate(_ fact: String, of known: [String]) -> Bool {
        let words = Set(fact.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        guard !words.isEmpty else { return true }
        return known.contains { existing in
            let existingWords = Set(
                existing.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            )
            let overlap = Double(words.intersection(existingWords).count) / Double(max(words.count, existingWords.count))
            return overlap > 0.6
        }
    }

    // MARK: - Generation

    private static func defaultGenerate(prompt: String, conversationModel: String) async throws -> String {
        #if canImport(FoundationModels) && !os(watchOS)
            if #available(macOS 26.0, iOS 26.0, *), AppleIntelligenceService.shared.isAvailable {
                return try await generateOnDevice(prompt: prompt)
            }
        #endif
        return try await generateWithModel(prompt: prompt, model: conversationModel)
    }

    #if canImport(FoundationModels) && !os(watchOS)
        @available(macOS 26.0, iOS 26.0, *)
        private static func generateOnDevice(prompt: String) async throws -> String {
            let service = AppleIntelligenceService.shared
            let sessionID = "memory-extraction-\(UUID().uuidString)"
            defer { service.clearSession(conversationId: sessionID) }
            var result: Result<String, Error>?
            await service.generateResponse(
                request: AppleIntelligenceRequest(
                    conversationID: sessionID,
                    prompt: prompt,
                    history: [],
                    systemInstructions: instructions,
                    temperature: 0
                ),
                onComplete: { result = .success($0) },
                onError: { result = .failure($0) }
            )
            guard let result else { throw CancellationError() }
            return try result.get()
        }
    #endif

    private static func generateWithModel(prompt: String, model: String) async throws -> String {
        let reply = ExtractionReply()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply.continuation = continuation
                guard !Task.isCancelled else {
                    reply.finish(CancellationError())
                    return
                }
                reply.request = AIService.shared.sendMessage(
                    messages: [Message(role: .user, content: prompt)],
                    model: model,
                    temperature: 0,
                    stream: false,
                    requestLane: .background,
                    onChunk: { reply.append($0) },
                    onComplete: { reply.finish(nil) },
                    onError: { reply.finish($0) }
                )
            }
        } onCancel: {
            // Stop the remote request and resume the caller, which then stores nothing.
            Task { @MainActor in reply.request?.cancel() }
            reply.finish(CancellationError())
        }
    }
}

/// Collects one reply and resumes its continuation exactly once.
private final class ExtractionReply: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    var continuation: CheckedContinuation<String, Error>?
    @MainActor var request: AITextRequest?

    func append(_ chunk: String) {
        lock.withLock { text += chunk }
    }

    func finish(_ error: Error?) {
        let (continuation, text) = lock.withLock {
            let pending = (self.continuation, self.text)
            self.continuation = nil
            return pending
        }
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: text)
        }
    }
}

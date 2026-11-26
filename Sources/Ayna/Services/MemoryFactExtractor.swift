import Foundation

@MainActor
final class MemoryFactExtractor {
    typealias Generate = @MainActor (_ prompt: String, _ conversationModel: String) async throws -> String

    static let shared = MemoryFactExtractor()

    static let defaultIdleDelay: Duration = .seconds(60)
    static let maximumFactsPerPass = 3
    static let maximumFactLength = 200
    private static let maximumPromptCharacters = 3000
    private static let maximumKnownFactCharacters = 1500

    private let idleDelay: Duration
    private let generate: Generate
    private let existingFacts: @MainActor () -> [UserMemoryFact]
    private let storeFact: @MainActor (String) -> Void
    private var idleTasks: [UUID: Task<Void, Never>] = [:]
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
        guard !Task.isCancelled else { return }
        examinedMessageIDs[conversation.id, default: []].formUnion(request.includedMessageIDs)

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

    static let instructions = """
    You extract durable facts about a user from messages they wrote to an assistant. \
    A durable fact stays true for months: their name, job, location, tools they use, lasting \
    preferences, ongoing projects. Ignore one-off requests, questions, and anything about other \
    people. Never include secrets such as passwords, keys, or financial or health details.
    """

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
        var knownLines: [String] = []
        var knownLength = 0
        for fact in existingFacts {
            let line = "- \(fact.prefix(maximumFactLength))"
            guard knownLength + line.count <= maximumKnownFactCharacters else { break }
            knownLines.append(line)
            knownLength += line.count + 1
        }
        let known = knownLines.isEmpty ? "(none)" : knownLines.joined(separator: "\n")
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
            .map(\.self)
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
            Task { @MainActor in reply.request?.cancel() }
            reply.finish(CancellationError())
        }
    }
}

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

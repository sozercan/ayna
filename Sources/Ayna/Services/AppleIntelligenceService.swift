//
//  AppleIntelligenceService.swift
//  ayna
//
//  Created on 11/6/25.
//

import Combine
import Foundation
import os.log

struct AppleIntelligenceToolCall: Equatable, Sendable {
    let id: String
    let name: String
    let argumentsJSON: String
}

struct AppleIntelligenceHistoryEntry: Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case user
        case assistant
        case tool
    }

    let role: Role
    let content: String
    let toolName: String?
    let toolCallID: String?
    let toolCalls: [AppleIntelligenceToolCall]

    init(
        role: Role,
        content: String,
        toolName: String? = nil,
        toolCallID: String? = nil,
        toolCalls: [AppleIntelligenceToolCall] = []
    ) {
        self.role = role
        self.content = content
        self.toolName = toolName
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }
}

struct AppleIntelligenceRequest: Sendable {
    let conversationID: String
    let prompt: String
    let history: [AppleIntelligenceHistoryEntry]
    let systemInstructions: String
    let temperature: Double
}

struct AppleIntelligenceTranscriptEntry: Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case user
        case assistant
    }

    let role: Role
    let content: String
}

enum AppleIntelligenceTranscriptBuilder {
    static func entries(
        from history: [AppleIntelligenceHistoryEntry]
    ) -> [AppleIntelligenceTranscriptEntry] {
        var toolOutputQueues = history.reduce(into: [String: [AppleIntelligenceHistoryEntry]]()) { outputs, entry in
            if entry.role == .tool, let toolCallID = entry.toolCallID {
                outputs[toolCallID, default: []].append(entry)
            }
        }
        var transcript: [AppleIntelligenceTranscriptEntry] = []
        for entry in history where entry.role != .tool {
            switch entry.role {
            case .user:
                transcript.append(.init(role: .user, content: entry.content))
            case .assistant:
                var responseParts = entry.content.isEmpty ? [] : [entry.content]
                for call in entry.toolCalls {
                    guard var outputs = toolOutputQueues[call.id], !outputs.isEmpty else { continue }
                    let output = outputs.removeFirst()
                    toolOutputQueues[call.id] = outputs
                    responseParts.append(
                        "Tool interaction — \(call.name)\nArguments: \(call.argumentsJSON)\nResult: \(output.content)"
                    )
                }
                if !responseParts.isEmpty {
                    transcript.append(.init(role: .assistant, content: responseParts.joined(separator: "\n\n")))
                }
            case .tool:
                break
            }
        }
        return transcript
    }
}

@MainActor
protocol AppleIntelligenceServing: AnyObject {
    var isAvailable: Bool { get }
    var contextSize: Int { get }
    func availabilityDescription() -> String
    func clearSession(conversationId: String)
    func tokenCount(for request: AppleIntelligenceRequest) async -> Int?
    func streamResponse(
        request: AppleIntelligenceRequest,
        onChunk: @escaping @MainActor @Sendable (String) -> Void,
        onComplete: @escaping @MainActor @Sendable () -> Void,
        onError: @escaping @MainActor @Sendable (Error) -> Void
    ) async
    func generateResponse(
        request: AppleIntelligenceRequest,
        onComplete: @escaping @MainActor @Sendable (String) -> Void,
        onError: @escaping @MainActor @Sendable (Error) -> Void
    ) async
}

enum AppleIntelligenceRetryGate {
    @MainActor
    static func prepare(
        clearSession: @MainActor () -> Void,
        delay: @escaping @MainActor @Sendable () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(500))
        }
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        clearSession()
        do {
            try await delay()
        } catch {
            return false
        }
        return !Task.isCancelled
    }
}

enum AppleIntelligenceError: LocalizedError {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unavailable(String)
    case sessionCreationFailed
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotEligible:
            "This device is not eligible for Apple Intelligence"
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is not enabled in System Settings"
        case .modelNotReady:
            "Apple Intelligence model assets are not downloaded yet"
        case let .unavailable(reason):
            "Apple Intelligence is unavailable: \(reason)"
        case .sessionCreationFailed:
            "Failed to create Apple Intelligence session"
        case let .generationFailed(error):
            "Response generation failed: \(error)"
        }
    }
}

#if canImport(FoundationModels) && !os(watchOS)
    import FoundationModels

    @available(macOS 26.0, iOS 26.0, *)
    @MainActor
    class AppleIntelligenceService: ObservableObject, AppleIntelligenceServing {
        static let shared = AppleIntelligenceService()

        @Published var model = SystemLanguageModel.default
        private var sessions: [String: LanguageModelSession] = [:]
        private let sessionsLock = NSLock()
        private func log(
            _ message: String,
            level: OSLogType = .default,
            metadata: [String: String] = [:]
        ) {
            DiagnosticsLogger.log(
                .appleIntelligence,
                level: level,
                message: message,
                metadata: metadata
            )
        }

        private init() {}

        /// Check if Apple Intelligence is available on this device
        var isAvailable: Bool {
            model.isAvailable
        }

        var contextSize: Int {
            #if compiler(>=6.3)
                model.contextSize
            #else
                4096
            #endif
        }

        var availability: SystemLanguageModel.Availability {
            model.availability
        }

        func availabilityDescription() -> String {
            switch availability {
            case .available:
                return "Available"
            case let .unavailable(reason):
                switch reason {
                case .deviceNotEligible:
                    return "Device not eligible for Apple Intelligence"
                case .appleIntelligenceNotEnabled:
                    return "Apple Intelligence not enabled in System Settings"
                case .modelNotReady:
                    return "Model assets not downloaded yet"
                @unknown default:
                    return "Unknown availability issue"
                }
            @unknown default:
                return "Unknown availability status"
            }
        }

        func tokenCount(for request: AppleIntelligenceRequest) async -> Int? {
            #if compiler(>=6.3)
                guard #available(macOS 26.4, iOS 26.4, *) else { return nil }
                do {
                    let historyTokens = try await model.tokenCount(for: transcriptEntries(
                        systemInstructions: request.systemInstructions,
                        history: request.history
                    ))
                    let promptTokens = try await model.tokenCount(for: request.prompt)
                    return historyTokens + promptTokens
                } catch {
                    return nil
                }
            #else
                return nil
            #endif
        }

        private func transcriptEntries(
            systemInstructions: String,
            history: [AppleIntelligenceHistoryEntry]
        ) -> [Transcript.Entry] {
            var entries: [Transcript.Entry] = [
                .instructions(Transcript.Instructions(
                    segments: [.text(.init(content: systemInstructions))],
                    toolDefinitions: []
                )),
            ]
            for entry in AppleIntelligenceTranscriptBuilder.entries(from: history) {
                let segment = Transcript.Segment.text(.init(content: entry.content))
                switch entry.role {
                case .user:
                    entries.append(.prompt(.init(segments: [segment])))
                case .assistant:
                    entries.append(.response(.init(assetIDs: [], segments: [segment])))
                }
            }
            return entries
        }

        /// Get or create a session for a conversation
        private func getSession(
            conversationId: String,
            systemInstructions: String,
            history: [AppleIntelligenceHistoryEntry]
        ) -> LanguageModelSession {
            sessionsLock.lock()
            defer { sessionsLock.unlock() }

            if let existingSession = sessions[conversationId] {
                return existingSession
            }

            let newSession = LanguageModelSession(transcript: Transcript(entries: transcriptEntries(
                systemInstructions: systemInstructions,
                history: history
            )))
            sessions[conversationId] = newSession
            return newSession
        }

        /// Clear session for a conversation
        func clearSession(conversationId: String) {
            sessionsLock.lock()
            defer { sessionsLock.unlock() }
            sessions.removeValue(forKey: conversationId)
            log("Cleared Apple Intelligence session", metadata: ["conversationId": conversationId])
        }

        /// Clear all sessions
        func clearAllSessions() {
            sessionsLock.lock()
            defer { sessionsLock.unlock() }
            sessions.removeAll()
            log("Cleared all Apple Intelligence sessions")
        }

        /// Stream response
        func streamResponse(
            request: AppleIntelligenceRequest,
            onChunk: @escaping @MainActor @Sendable (String) -> Void,
            onComplete: @escaping @MainActor @Sendable () -> Void,
            onError: @escaping @MainActor @Sendable (Error) -> Void
        ) async {
            guard !Task.isCancelled else { return }
            // Check availability
            guard isAvailable else {
                log(
                    "Apple Intelligence stream unavailable",
                    level: .error,
                    metadata: ["conversationId": request.conversationID, "reason": availabilityDescription()]
                )
                onError(getAvailabilityError())
                return
            }

            log("Starting Apple Intelligence stream", metadata: ["conversationId": request.conversationID])

            let maxRetries = 2

            for attempt in 1 ... maxRetries {
                guard !Task.isCancelled else { return }
                // Get or create session
                let session = getSession(
                    conversationId: request.conversationID,
                    systemInstructions: request.systemInstructions,
                    history: request.history
                )

                // Create generation options
                let options = GenerationOptions(temperature: request.temperature)

                do {
                    // Stream the response
                    let stream = session.streamResponse(to: request.prompt, options: options)

                    var previousContent = ""
                    var hasReceivedContent = false

                    for try await snapshot in stream {
                        try Task.checkCancellation()
                        // snapshot.content contains the full response so far, not just the delta
                        // Calculate the new text by comparing with previous content
                        let currentContent = snapshot.content
                        if currentContent.hasPrefix(previousContent) {
                            let delta = String(currentContent.dropFirst(previousContent.count))
                            if !delta.isEmpty {
                                onChunk(delta)
                                hasReceivedContent = true
                            }
                        } else {
                            // If content doesn't have expected prefix, send full content
                            onChunk(currentContent)
                            hasReceivedContent = true
                        }
                        previousContent = currentContent
                    }

                    if hasReceivedContent {
                        try Task.checkCancellation()
                        onComplete()
                        log("Completed Apple Intelligence stream", metadata: ["conversationId": request.conversationID])
                        return
                    } else {
                        if attempt < maxRetries {
                            log(
                                "Apple Intelligence stream returned no content, retrying...",
                                level: .default,
                                metadata: ["conversationId": request.conversationID, "attempt": "\(attempt)"]
                            )
                            guard await AppleIntelligenceRetryGate.prepare(clearSession: {
                                self.clearSession(conversationId: request.conversationID)
                            }) else {
                                return
                            }
                            continue
                        } else {
                            try Task.checkCancellation()
                            onComplete()
                            log("Completed Apple Intelligence stream (empty)", metadata: ["conversationId": request.conversationID])
                            return
                        }
                    }
                } catch is CancellationError {
                    log("Apple Intelligence stream cancelled", metadata: ["conversationId": request.conversationID])
                    return
                } catch {
                    log(
                        "Apple Intelligence stream failed",
                        level: .error,
                        metadata: ["conversationId": request.conversationID, "error": error.localizedDescription, "attempt": "\(attempt)"]
                    )
                    guard !Task.isCancelled else { return }

                    if attempt < maxRetries {
                        guard await AppleIntelligenceRetryGate.prepare(clearSession: {
                            self.clearSession(conversationId: request.conversationID)
                        }) else {
                            return
                        }
                        continue
                    }

                    onError(AppleIntelligenceError.generationFailed(error.localizedDescription))
                    return
                }
            }
        }

        /// Non-streaming response
        func generateResponse(
            request: AppleIntelligenceRequest,
            onComplete: @escaping @MainActor @Sendable (String) -> Void,
            onError: @escaping @MainActor @Sendable (Error) -> Void
        ) async {
            guard !Task.isCancelled else { return }
            // Check availability
            guard isAvailable else {
                log(
                    "Apple Intelligence response unavailable",
                    level: .error,
                    metadata: ["conversationId": request.conversationID, "reason": availabilityDescription()]
                )
                onError(getAvailabilityError())
                return
            }

            log("Generating Apple Intelligence response", metadata: ["conversationId": request.conversationID])

            // Get or create session
            let session = getSession(
                conversationId: request.conversationID,
                systemInstructions: request.systemInstructions,
                history: request.history
            )

            // Create generation options
            let options = GenerationOptions(temperature: request.temperature)

            do {
                // Generate the response
                let response = try await session.respond(to: request.prompt, options: options)

                try Task.checkCancellation()
                onComplete(response.content)
                log("Generated Apple Intelligence response", metadata: ["conversationId": request.conversationID])
            } catch is CancellationError {
                log("Apple Intelligence generation cancelled", metadata: ["conversationId": request.conversationID])
            } catch {
                guard !Task.isCancelled else { return }
                log(
                    "Apple Intelligence generation failed",
                    level: .error,
                    metadata: ["conversationId": request.conversationID, "error": error.localizedDescription]
                )
                onError(AppleIntelligenceError.generationFailed(error.localizedDescription))
            }
        }

        private func getAvailabilityError() -> Error {
            switch availability {
            case .available:
                return AppleIntelligenceError.unavailable("Unknown")
            case let .unavailable(reason):
                switch reason {
                case .deviceNotEligible:
                    return AppleIntelligenceError.deviceNotEligible
                case .appleIntelligenceNotEnabled:
                    return AppleIntelligenceError.appleIntelligenceNotEnabled
                case .modelNotReady:
                    return AppleIntelligenceError.modelNotReady
                @unknown default:
                    return AppleIntelligenceError.unavailable("Unknown reason")
                }
            @unknown default:
                return AppleIntelligenceError.unavailable("Unknown status")
            }
        }
    }

#else

    @available(macOS 26.0, iOS 26.0, *)
    @MainActor
    class AppleIntelligenceService: ObservableObject, AppleIntelligenceServing {
        static let shared = AppleIntelligenceService()

        var isAvailable: Bool {
            false
        }

        var contextSize: Int {
            0
        }

        func availabilityDescription() -> String {
            "Apple Intelligence frameworks are not installed on this system"
        }

        func tokenCount(for _: AppleIntelligenceRequest) async -> Int? {
            nil
        }

        func clearSession(conversationId _: String) {}

        func clearAllSessions() {}

        func streamResponse(
            request: AppleIntelligenceRequest,
            onChunk _: @escaping @MainActor @Sendable (String) -> Void,
            onComplete _: @escaping @MainActor @Sendable () -> Void,
            onError: @escaping @MainActor @Sendable (Error) -> Void
        ) async {
            DiagnosticsLogger.log(
                .appleIntelligence,
                level: .error,
                message: "Apple Intelligence unavailable on this platform",
                metadata: ["conversationId": request.conversationID]
            )

            onError(getAvailabilityError())
        }

        func generateResponse(
            request: AppleIntelligenceRequest,
            onComplete _: @escaping @MainActor @Sendable (String) -> Void,
            onError: @escaping @MainActor @Sendable (Error) -> Void
        ) async {
            DiagnosticsLogger.log(
                .appleIntelligence,
                level: .error,
                message: "Apple Intelligence unavailable on this platform",
                metadata: ["conversationId": request.conversationID]
            )

            onError(getAvailabilityError())
        }

        private func getAvailabilityError() -> Error {
            AppleIntelligenceError.unavailable("Apple Intelligence frameworks are not installed on this system")
        }
    }

#endif

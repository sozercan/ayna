//
//  AppleIntelligenceService.swift
//  ayna
//
//  Created on 11/6/25.
//

import Combine
import Foundation
import os.log

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

#if canImport(FoundationModels)
    import FoundationModels

    @available(macOS 26.0, iOS 26.0, *)
    @MainActor
    class AppleIntelligenceService: ObservableObject {
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

        /// Get or create a session for a conversation
        private func getSession(
            conversationId: String,
            systemInstructions: String
        ) -> LanguageModelSession {
            sessionsLock.lock()
            defer { sessionsLock.unlock() }

            if let existingSession = sessions[conversationId] {
                return existingSession
            }

            let newSession = LanguageModelSession(instructions: systemInstructions)
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
            conversationId: String,
            prompt: String,
            systemInstructions: String = "You are a helpful assistant.",
            temperature: Double = 0.7,
            onChunk: @escaping (String) -> Void,
            onComplete: @escaping () -> Void,
            onError: @escaping (Error) -> Void
        ) async {
            // Check availability
            guard isAvailable else {
                log(
                    "Apple Intelligence stream unavailable",
                    level: .error,
                    metadata: ["conversationId": conversationId, "reason": availabilityDescription()]
                )
                onError(getAvailabilityError())
                return
            }

            log("Starting Apple Intelligence stream", metadata: ["conversationId": conversationId])

            let maxRetries = 2

            for attempt in 1 ... maxRetries {
                // Get or create session
                let session = getSession(
                    conversationId: conversationId,
                    systemInstructions: systemInstructions
                )

                // Create generation options
                let options = GenerationOptions(temperature: temperature)

                do {
                    // Stream the response
                    let stream = session.streamResponse(to: prompt, options: options)

                    var previousContent = ""
                    var hasReceivedContent = false

                    for try await snapshot in stream {
                        await MainActor.run {
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
                    }

                    if hasReceivedContent {
                        await MainActor.run {
                            onComplete()
                        }
                        log("Completed Apple Intelligence stream", metadata: ["conversationId": conversationId])
                        return
                    } else {
                        if attempt < maxRetries {
                            log(
                                "Apple Intelligence stream returned no content, retrying...",
                                level: .default,
                                metadata: ["conversationId": conversationId, "attempt": "\(attempt)"]
                            )
                            clearSession(conversationId: conversationId)
                            try? await Task.sleep(for: .milliseconds(500))
                            continue
                        } else {
                            await MainActor.run {
                                onComplete()
                            }
                            log("Completed Apple Intelligence stream (empty)", metadata: ["conversationId": conversationId])
                            return
                        }
                    }
                } catch is CancellationError {
                    log("Apple Intelligence stream cancelled", metadata: ["conversationId": conversationId])
                    return
                } catch {
                    log(
                        "Apple Intelligence stream failed",
                        level: .error,
                        metadata: ["conversationId": conversationId, "error": error.localizedDescription, "attempt": "\(attempt)"]
                    )

                    if attempt < maxRetries {
                        clearSession(conversationId: conversationId)
                        try? await Task.sleep(for: .milliseconds(500))
                        continue
                    }

                    await MainActor.run {
                        onError(AppleIntelligenceError.generationFailed(error.localizedDescription))
                    }
                    return
                }
            }
        }

        /// Non-streaming response
        func generateResponse(
            conversationId: String,
            prompt: String,
            systemInstructions: String = "You are a helpful assistant.",
            temperature: Double = 0.7,
            onComplete: @escaping (String) -> Void,
            onError: @escaping (Error) -> Void
        ) async {
            // Check availability
            guard isAvailable else {
                log(
                    "Apple Intelligence response unavailable",
                    level: .error,
                    metadata: ["conversationId": conversationId, "reason": availabilityDescription()]
                )
                onError(getAvailabilityError())
                return
            }

            log("Generating Apple Intelligence response", metadata: ["conversationId": conversationId])

            // Get or create session
            let session = getSession(
                conversationId: conversationId,
                systemInstructions: systemInstructions
            )

            // Create generation options
            let options = GenerationOptions(temperature: temperature)

            do {
                // Generate the response
                let response = try await session.respond(to: prompt, options: options)

                await MainActor.run {
                    onComplete(response.content)
                }
                log("Generated Apple Intelligence response", metadata: ["conversationId": conversationId])
            } catch is CancellationError {
                log("Apple Intelligence generation cancelled", metadata: ["conversationId": conversationId])
            } catch {
                log(
                    "Apple Intelligence generation failed",
                    level: .error,
                    metadata: ["conversationId": conversationId, "error": error.localizedDescription]
                )
                await MainActor.run {
                    onError(AppleIntelligenceError.generationFailed(error.localizedDescription))
                }
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
    class AppleIntelligenceService: ObservableObject {
        static let shared = AppleIntelligenceService()

        var isAvailable: Bool {
            false
        }

        func availabilityDescription() -> String {
            "Apple Intelligence frameworks are not installed on this system"
        }

        func clearSession(conversationId _: String) {}

        func clearAllSessions() {}

        func streamResponse(
            conversationId: String,
            prompt _: String,
            systemInstructions _: String = "You are a helpful assistant.",
            temperature _: Double = 0.7,
            onChunk _: @escaping (String) -> Void,
            onComplete _: @escaping () -> Void,
            onError: @escaping (Error) -> Void
        ) async {
            DiagnosticsLogger.log(
                .appleIntelligence,
                level: .error,
                message: "Apple Intelligence unavailable on this platform",
                metadata: ["conversationId": conversationId]
            )

            await MainActor.run {
                onError(getAvailabilityError())
            }
        }

        func generateResponse(
            conversationId: String,
            prompt _: String,
            systemInstructions _: String = "You are a helpful assistant.",
            temperature _: Double = 0.7,
            onComplete _: @escaping (String) -> Void,
            onError: @escaping (Error) -> Void
        ) async {
            DiagnosticsLogger.log(
                .appleIntelligence,
                level: .error,
                message: "Apple Intelligence unavailable on this platform",
                metadata: ["conversationId": conversationId]
            )

            await MainActor.run {
                onError(getAvailabilityError())
            }
        }

        private func getAvailabilityError() -> Error {
            AppleIntelligenceError.unavailable("Apple Intelligence frameworks are not installed on this system")
        }
    }

#endif

//
//  AppleIntelligenceService.swift
//  ayna
//
//  Created on 11/6/25.
//

import Foundation
import FoundationModels

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
            return "This device is not eligible for Apple Intelligence"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is not enabled in System Settings"
        case .modelNotReady:
            return "Apple Intelligence model assets are not downloaded yet"
        case .unavailable(let reason):
            return "Apple Intelligence is unavailable: \(reason)"
        case .sessionCreationFailed:
            return "Failed to create Apple Intelligence session"
        case .generationFailed(let error):
            return "Response generation failed: \(error)"
        }
    }
}

@available(macOS 26.0, iOS 26.0, *)
class AppleIntelligenceService: ObservableObject {
    static let shared = AppleIntelligenceService()

    @Published var model = SystemLanguageModel.default
    private var sessions: [String: LanguageModelSession] = [:]
  private let sessionsLock = NSLock()

    private init() {}

    // Check if Apple Intelligence is available on this device
    var isAvailable: Bool {
        return model.isAvailable
    }

    var availability: SystemLanguageModel.Availability {
        return model.availability
    }

    func availabilityDescription() -> String {
        switch availability {
        case .available:
            return "Available"
        case .unavailable(let reason):
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

    // Get or create a session for a conversation
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

    // Clear session for a conversation
    func clearSession(conversationId: String) {
    sessionsLock.lock()
    defer { sessionsLock.unlock() }
        sessions.removeValue(forKey: conversationId)
    }

    // Clear all sessions
    func clearAllSessions() {
    sessionsLock.lock()
    defer { sessionsLock.unlock() }
        sessions.removeAll()
    }

    // Stream response
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
            onError(getAvailabilityError())
            return
        }

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
            for try await snapshot in stream {
                await MainActor.run {
                    // snapshot.content contains the full response so far, not just the delta
                    // Calculate the new text by comparing with previous content
                    let currentContent = snapshot.content
                    if currentContent.hasPrefix(previousContent) {
                        let delta = String(currentContent.dropFirst(previousContent.count))
                        if !delta.isEmpty {
                            onChunk(delta)
                        }
                    } else {
                        // If content doesn't have expected prefix, send full content
                        onChunk(currentContent)
                    }
                    previousContent = currentContent
                }
            }

            await MainActor.run {
                onComplete()
            }
        } catch {
            await MainActor.run {
                onError(AppleIntelligenceError.generationFailed(error.localizedDescription))
            }
        }
    }

    // Non-streaming response
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
            onError(getAvailabilityError())
            return
        }

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
        } catch {
            await MainActor.run {
                onError(AppleIntelligenceError.generationFailed(error.localizedDescription))
            }
        }
    }

    private func getAvailabilityError() -> Error {
        switch availability {
        case .available:
            return AppleIntelligenceError.unavailable("Unknown")
        case .unavailable(let reason):
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

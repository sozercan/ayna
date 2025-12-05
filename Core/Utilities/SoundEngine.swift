//
//  SoundEngine.swift
//  ayna
//
//  Design System: Sound Feedback
//  Centralized audio feedback for key user interactions.
//  Respects system silent switch and accessibility settings.
//

import AVFoundation
import os.log
import SwiftUI

#if os(iOS)
    import AudioToolbox
#endif

// MARK: - SoundEngine

/// Centralized sound engine for the Ayna design system.
/// Provides consistent audio feedback for key interactions.
///
/// Sounds are designed to be:
/// - Subtle and non-intrusive
/// - Respectful of silent switch (iOS) and mute settings
/// - Consistent with Apple's audio design guidelines
///
/// Usage:
/// ```swift
/// SoundEngine.play(.messageSent)
/// SoundEngine.play(.messageReceived)
/// ```
@MainActor
public final class SoundEngine {
    // MARK: - Singleton

    public static let shared = SoundEngine()

    // MARK: - Properties

    /// Whether sounds are enabled (user preference)
    @AppStorage("soundEffectsEnabled") private var soundsEnabled: Bool = true

    /// Audio players for custom sounds (cached for performance)
    private var players: [Sound: AVAudioPlayer] = [:]

    /// System sound IDs for iOS system sounds
    #if os(iOS)
        private var systemSoundIDs: [Sound: SystemSoundID] = [:]
    #endif

    // MARK: - Initialization

    private init() {
        configureAudioSession()
    }

    private func configureAudioSession() {
        #if os(iOS)
            do {
                // Use ambient category to respect silent switch and mix with other audio
                try AVAudioSession.sharedInstance().setCategory(
                    .ambient,
                    mode: .default,
                    options: [.mixWithOthers]
                )
            } catch {
                DiagnosticsLogger.log(
                    .app,
                    level: .error,
                    message: "⚠️ Failed to configure audio session",
                    metadata: ["error": error.localizedDescription]
                )
            }
        #endif
    }

    // MARK: - Sound Definitions

    /// Available sound effects
    public enum Sound: String, CaseIterable {
        /// Played when user sends a message
        case messageSent = "message_sent"

        /// Played when AI response completes
        case messageReceived = "message_received"

        /// Played when an error occurs
        case error

        /// Played when a new conversation is created
        case newConversation = "new_conversation"

        /// Played on successful action (copy, etc.)
        case success

        #if os(iOS)
            /// System sound ID for this sound (using Apple's built-in sounds)
            var systemSoundID: SystemSoundID {
                switch self {
                case .messageSent:
                    // Message sent - short "swoosh" sound (like iMessage)
                    1004 // Mail Sent
                case .messageReceived:
                    // Message received - gentle notification
                    1007 // SMS Received (subtle tri-tone)
                case .error:
                    // Error - system alert
                    1073 // Shake (error-like)
                case .newConversation:
                    // New conversation - light tap
                    1104 // Begin recording (subtle)
                case .success:
                    // Success - confirmation
                    1057 // Photo shutter (subtle click)
                }
            }
        #endif

        #if os(macOS)
            /// System sound name for macOS
            var macOSSoundName: NSSound.Name? {
                switch self {
                case .messageSent:
                    NSSound.Name("Morse") // Short, subtle
                case .messageReceived:
                    NSSound.Name("Tink") // Gentle notification
                case .error:
                    NSSound.Name("Basso") // Error sound
                case .newConversation:
                    NSSound.Name("Pop") // Light tap
                case .success:
                    NSSound.Name("Purr") // Confirmation
                }
            }
        #endif
    }

    // MARK: - Playback

    /// Play a sound effect
    /// - Parameter sound: The sound to play
    public func play(_ sound: Sound) {
        guard soundsEnabled else { return }

        #if os(iOS)
            playSystemSound(sound)
        #elseif os(macOS)
            playMacOSSound(sound)
        #endif
    }

    #if os(iOS)
        private func playSystemSound(_ sound: Sound) {
            // Use AudioServicesPlaySystemSound for silent switch support
            // This automatically respects the hardware silent switch
            AudioServicesPlaySystemSound(sound.systemSoundID)

            DiagnosticsLogger.log(
                .app,
                level: .info,
                message: "🔊 Playing sound: \(sound.rawValue)"
            )
        }
    #endif

    #if os(macOS)
        private func playMacOSSound(_ sound: Sound) {
            guard let soundName = sound.macOSSoundName,
                  let nsSound = NSSound(named: soundName)
            else {
                DiagnosticsLogger.log(
                    .app,
                    level: .error,
                    message: "⚠️ Sound not found: \(sound.rawValue)"
                )
                return
            }

            // Play asynchronously to not block UI
            nsSound.play()

            DiagnosticsLogger.log(
                .app,
                level: .info,
                message: "🔊 Playing sound: \(sound.rawValue)"
            )
        }
    #endif

    // MARK: - Convenience Methods

    /// Play message sent sound
    public static func messageSent() {
        shared.play(.messageSent)
    }

    /// Play message received sound
    public static func messageReceived() {
        shared.play(.messageReceived)
    }

    /// Play error sound
    public static func error() {
        shared.play(.error)
    }

    /// Play new conversation sound
    public static func newConversation() {
        shared.play(.newConversation)
    }

    /// Play success sound
    public static func success() {
        shared.play(.success)
    }

    // MARK: - Settings

    /// Toggle sound effects on/off
    public var isEnabled: Bool {
        get { soundsEnabled }
        set { soundsEnabled = newValue }
    }
}

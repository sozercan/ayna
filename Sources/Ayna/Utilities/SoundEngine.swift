import AVFoundation
import os.log
import SwiftUI

#if os(iOS)
    import AudioToolbox
#endif

@MainActor
public final class SoundEngine {
    public static let shared = SoundEngine()

    @AppStorage("soundEffectsEnabled") private var soundsEnabled: Bool = true

    private var players: [Sound: AVAudioPlayer] = [:]

    #if os(iOS)
        private var systemSoundIDs: [Sound: SystemSoundID] = [:]
    #endif

    private init() {
        configureAudioSession()
    }

    private func configureAudioSession() {
        #if os(iOS)
            do {
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

    public enum Sound: String, CaseIterable {
        case messageSent = "message_sent"

        case messageReceived = "message_received"

        case error

        case newConversation = "new_conversation"

        case success

        #if os(iOS)
            var systemSoundID: SystemSoundID {
                switch self {
                case .messageSent:
                    1004
                case .messageReceived:
                    1007
                case .error:
                    1073
                case .newConversation:
                    1104
                case .success:
                    1057
                }
            }
        #endif

        #if os(macOS)
            var macOSSoundName: NSSound.Name? {
                switch self {
                case .messageSent:
                    NSSound.Name("Morse")
                case .messageReceived:
                    NSSound.Name("Tink")
                case .error:
                    NSSound.Name("Basso")
                case .newConversation:
                    NSSound.Name("Pop")
                case .success:
                    NSSound.Name("Purr")
                }
            }
        #endif
    }

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

            nsSound.play()

            DiagnosticsLogger.log(
                .app,
                level: .info,
                message: "🔊 Playing sound: \(sound.rawValue)"
            )
        }
    #endif

    public static func messageSent() {
        shared.play(.messageSent)
    }

    public static func messageReceived() {
        shared.play(.messageReceived)
    }

    public static func error() {
        shared.play(.error)
    }

    public static func newConversation() {
        shared.play(.newConversation)
    }

    public static func success() {
        shared.play(.success)
    }

    public var isEnabled: Bool {
        get { soundsEnabled }
        set { soundsEnabled = newValue }
    }
}

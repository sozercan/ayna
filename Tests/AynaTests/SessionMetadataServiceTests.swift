@testable import Ayna
import Foundation
import Testing

@Suite("SessionMetadataService Tests")
@MainActor
struct SessionMetadataServiceTests {
    @Test("Prefers foreground active scene over inactive scenes for dark mode")
    func prefersForegroundActiveScene() {
        let scenes: [(isForegroundActive: Bool, isDark: Bool)] = [
            (isForegroundActive: false, isDark: true),
            (isForegroundActive: true, isDark: false)
        ]

        #expect(SessionMetadataService.isDarkMode(in: scenes) == false)
    }

    @Test("Returns true when foreground active scene is dark")
    func returnsTrueWhenForegroundActiveSceneIsDark() {
        let scenes: [(isForegroundActive: Bool, isDark: Bool)] = [
            (isForegroundActive: false, isDark: false),
            (isForegroundActive: true, isDark: true)
        ]

        #expect(SessionMetadataService.isDarkMode(in: scenes) == true)
    }

    @Test("Falls back to first connected scene when none is foreground active")
    func fallsBackToFirstConnectedScene() {
        let darkFallback: [(isForegroundActive: Bool, isDark: Bool)] = [
            (isForegroundActive: false, isDark: true),
            (isForegroundActive: false, isDark: false)
        ]
        let lightFallback: [(isForegroundActive: Bool, isDark: Bool)] = [
            (isForegroundActive: false, isDark: false),
            (isForegroundActive: false, isDark: true)
        ]

        #expect(SessionMetadataService.isDarkMode(in: darkFallback) == true)
        #expect(SessionMetadataService.isDarkMode(in: lightFallback) == false)
    }

    @Test("Defaults to false when no scenes are connected")
    func defaultsToFalseWhenNoScenesConnected() {
        #expect(SessionMetadataService.isDarkMode(in: []) == false)
    }

    @Test("Collects metadata with valid platform and device type")
    func collectsMetadata() {
        let metadata = SessionMetadataService.shared.collectMetadata()

        #if os(macOS)
            #expect(metadata.platform == .macOS)
            #expect(metadata.deviceType == .desktop)
        #elseif os(iOS)
            #expect(metadata.platform == .iOS)
        #elseif os(watchOS)
            #expect(metadata.platform == .watchOS)
            #expect(metadata.deviceType == .watch)
        #endif
        #expect(!metadata.appVersion.isEmpty)
    }
}

@testable import Ayna
import Foundation
import Testing

@Suite("Deterministic Readiness Tests", .tags(.viewModel), .serialized)
struct DeterministicReadinessTests {
    @MainActor
    private func makeManager(directory: URL) -> ConversationManager {
        let store = TestHelpers.makeTestStore(
            directory: directory,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage()
        )
        return ConversationManager(
            store: store,
            saveDebounceDuration: .zero,
            searchIndexWarmupEnabled: false,
            startsLoadingImmediately: false
        )
    }

    @Test
    @MainActor
    func `queuePendingSend stores and consumes conversation once`() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let manager = makeManager(directory: directory)
        manager.createNewConversation()
        let conversation = try #require(manager.conversations.first)

        #expect(!manager.hasPendingSend(for: conversation.id))
        manager.queuePendingSend(for: conversation.id)
        manager.queuePendingSend(for: conversation.id)

        #expect(manager.pendingSendConversationIds == [conversation.id])
        #expect(manager.hasPendingSend(for: conversation.id))
        #expect(manager.consumePendingSend(for: conversation.id))
        #expect(!manager.hasPendingSend(for: conversation.id))
        #expect(!manager.consumePendingSend(for: conversation.id))
    }

    @Test
    @MainActor
    func `deleting or clearing conversations removes queued pending sends`() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let manager = makeManager(directory: directory)
        manager.createNewConversation()
        let first = try #require(manager.conversations.first)
        manager.createNewConversation()
        let second = try #require(manager.conversations.first)

        manager.queuePendingSend(for: first.id)
        manager.queuePendingSend(for: second.id)
        _ = manager.deleteConversation(first)

        #expect(!manager.hasPendingSend(for: first.id))
        #expect(manager.hasPendingSend(for: second.id))

        _ = manager.clearAllConversations()
        #expect(manager.pendingSendConversationIds.isEmpty)
    }

    #if os(macOS)
        @Test
        @MainActor
        func `createConversationWithContext queues deterministic pending send without delay`() throws {
            let directory = try TestHelpers.makeTemporaryDirectory()
            let manager = makeManager(directory: directory)

            let conversation = manager.createConversationWithContext(
                appName: "Xcode",
                windowTitle: "aynaApp.swift",
                contentType: "Source Code",
                content: "let value = 1",
                userMessage: "Explain this"
            )

            #expect(manager.selectedConversationId == conversation.id)
            #expect(manager.hasPendingSend(for: conversation.id))
            #expect(manager.consumePendingSend(for: conversation.id))
            #expect(!manager.hasPendingSend(for: conversation.id))
        }

        @Test
        @MainActor
        func `main window coordinator opens SwiftUI window group and signals readiness`() async {
            let coordinator = MainWindowCoordinator()
            var openWindowCallCount = 0
            var activateCallCount = 0

            coordinator.register(openWindow: {
                openWindowCallCount += 1
            })

            let opened = coordinator.openOrFocusMainWindow(
                windows: { [] },
                activateApp: { activateCallCount += 1 }
            )

            #expect(opened)
            #expect(openWindowCallCount == 1)
            #expect(activateCallCount == 1)
            #expect(!coordinator.isMainWindowReady)

            let waiter = Task { @MainActor in
                await coordinator.waitUntilMainWindowReady()
                return true
            }
            await Task.yield()

            coordinator.markMainWindowReady()
            let becameReady = await waiter.value

            #expect(becameReady)
            #expect(coordinator.isMainWindowReady)
        }

        @Test
        @MainActor
        func `main window coordinator deduplicates in-flight open requests until readiness`() {
            let coordinator = MainWindowCoordinator()
            var openWindowCallCount = 0

            coordinator.register(openWindow: {
                openWindowCallCount += 1
            })

            let firstOpen = coordinator.openOrFocusMainWindow(
                windows: { [] },
                activateApp: {}
            )
            let secondOpen = coordinator.openOrFocusMainWindow(
                windows: { [] },
                activateApp: {}
            )

            #expect(firstOpen)
            #expect(secondOpen)
            #expect(openWindowCallCount == 1)
            #expect(coordinator.isOpenRequestInFlight)

            coordinator.markMainWindowReady()
            #expect(!coordinator.isOpenRequestInFlight)
            #expect(coordinator.isMainWindowReady)

            coordinator.markMainWindowClosed()
            let reopened = coordinator.openOrFocusMainWindow(
                windows: { [] },
                activateApp: {}
            )

            #expect(reopened)
            #expect(openWindowCallCount == 2)
        }

        @Test
        @MainActor
        func `app delegate resolves attached conversation manager deterministically`() async throws {
            let previousManager = AynaAppDelegate.conversationManager
            defer {
                AynaAppDelegate.resetForTesting()
                if let previousManager {
                    AynaAppDelegate.attachConversationManager(previousManager)
                }
            }

            AynaAppDelegate.resetForTesting()
            let directory = try TestHelpers.makeTemporaryDirectory()
            let manager = makeManager(directory: directory)

            let waiter = Task { @MainActor in
                await AynaAppDelegate.waitForAttachedConversationManager()
            }
            await Task.yield()

            AynaAppDelegate.attachConversationManager(manager)
            let resolved = await waiter.value

            #expect(resolved === manager)
        }
    #endif
}

#if os(macOS)

    @testable import Ayna
    import Foundation
    import SwiftUI
    import Testing

    @Suite("Chat Attachment Drop Tests", .tags(.fast))
    @MainActor
    struct ChatAttachmentDropTests {
        @Test(.timeLimit(.minutes(1)))
        func `a pending drop disables sending and attaches when it finishes`() async {
            let state = DropState()
            let gate = DropLoadGate()
            let fileURL = URL(fileURLWithPath: "/tmp/photo.png")

            let task = ChatAttachmentDrop.receiveDrop(
                loadFileURLs: { await gate.wait(returning: [fileURL]) },
                attachedFiles: state.attachedFilesBinding,
                pastedImages: state.pastedImagesBinding,
                importSessionID: state.sessionBinding,
                pendingDropCount: state.pendingBinding
            )

            #expect(state.pendingDropCount == 1)
            gate.open()
            await task.value

            #expect(state.pendingDropCount == 0)
            #expect(state.attachedFiles == [fileURL])
        }

        @Test(.timeLimit(.minutes(1)))
        func `overlapping drops keep sending disabled until every drop finishes`() async {
            let state = DropState()
            let firstGate = DropLoadGate()
            let secondGate = DropLoadGate()
            let firstURL = URL(fileURLWithPath: "/tmp/first.png")
            let secondURL = URL(fileURLWithPath: "/tmp/second.png")

            let first = ChatAttachmentDrop.receiveDrop(
                loadFileURLs: { await firstGate.wait(returning: [firstURL]) },
                attachedFiles: state.attachedFilesBinding,
                pastedImages: state.pastedImagesBinding,
                importSessionID: state.sessionBinding,
                pendingDropCount: state.pendingBinding
            )
            let second = ChatAttachmentDrop.receiveDrop(
                loadFileURLs: { await secondGate.wait(returning: [secondURL]) },
                attachedFiles: state.attachedFilesBinding,
                pastedImages: state.pastedImagesBinding,
                importSessionID: state.sessionBinding,
                pendingDropCount: state.pendingBinding
            )
            #expect(state.pendingDropCount == 2)

            firstGate.open()
            await first.value
            #expect(state.pendingDropCount == 1)

            secondGate.open()
            await second.value
            #expect(state.pendingDropCount == 0)
            #expect(state.attachedFiles == [firstURL, secondURL])
        }

        @Test(.timeLimit(.minutes(1)))
        func `a drop that finishes after the draft was sent is discarded`() async {
            let state = DropState()
            let gate = DropLoadGate()

            let task = ChatAttachmentDrop.receiveDrop(
                loadFileURLs: { await gate.wait(returning: [URL(fileURLWithPath: "/tmp/photo.png")]) },
                attachedFiles: state.attachedFilesBinding,
                pastedImages: state.pastedImagesBinding,
                importSessionID: state.sessionBinding,
                pendingDropCount: state.pendingBinding
            )
            state.sessionID = UUID()
            gate.open()
            await task.value

            #expect(state.pendingDropCount == 0)
            #expect(state.attachedFiles.isEmpty)
        }
    }

    @MainActor
    private final class DropState {
        var attachedFiles: [URL] = []
        var pastedImages: [PastedImage] = []
        var sessionID = UUID()
        var pendingDropCount = 0

        var attachedFilesBinding: Binding<[URL]> {
            Binding(get: { self.attachedFiles }, set: { self.attachedFiles = $0 })
        }

        var pastedImagesBinding: Binding<[PastedImage]> {
            Binding(get: { self.pastedImages }, set: { self.pastedImages = $0 })
        }

        var sessionBinding: Binding<UUID> {
            Binding(get: { self.sessionID }, set: { self.sessionID = $0 })
        }

        var pendingBinding: Binding<Int> {
            Binding(get: { self.pendingDropCount }, set: { self.pendingDropCount = $0 })
        }
    }

    @MainActor
    private final class DropLoadGate {
        private var isOpen = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait(returning fileURLs: [URL]) async -> [URL] {
            if !isOpen {
                await withCheckedContinuation { continuation = $0 }
            }
            return fileURLs
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

#endif

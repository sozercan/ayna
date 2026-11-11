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
                isImporting: state.importingBinding
            )

            #expect(state.isImporting)
            gate.open()
            await task.value

            #expect(!state.isImporting)
            #expect(state.attachedFiles == [fileURL])
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
                isImporting: state.importingBinding
            )
            state.sessionID = UUID()
            gate.open()
            await task.value

            #expect(!state.isImporting)
            #expect(state.attachedFiles.isEmpty)
        }
    }

    @MainActor
    private final class DropState {
        var attachedFiles: [URL] = []
        var pastedImages: [PastedImage] = []
        var sessionID = UUID()
        var isImporting = false

        var attachedFilesBinding: Binding<[URL]> {
            Binding(get: { self.attachedFiles }, set: { self.attachedFiles = $0 })
        }

        var pastedImagesBinding: Binding<[PastedImage]> {
            Binding(get: { self.pastedImages }, set: { self.pastedImages = $0 })
        }

        var sessionBinding: Binding<UUID> {
            Binding(get: { self.sessionID }, set: { self.sessionID = $0 })
        }

        var importingBinding: Binding<Bool> {
            Binding(get: { self.isImporting }, set: { self.isImporting = $0 })
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

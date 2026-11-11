#if os(macOS)
//
//  ChatAttachmentDrop.swift
//  ayna
//
//  Attaches files dragged onto a chat screen, matching the attach button.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum ChatAttachmentDrop {
    /// Appends dropped files to the composer's attachments, skipping folders and over-limit images.
    static func attach(_ droppedFiles: [URL], to attachedFiles: Binding<[URL]>, pastedImageCount: Int) {
        let files = droppedFiles.filter { fileURL in
            (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        }
        let selection = ChatDraftContent.filesToAttach(
            files,
            existing: attachedFiles.wrappedValue,
            inMemoryImageCount: pastedImageCount
        )
        attachedFiles.wrappedValue.append(contentsOf: selection.accepted)

        if selection.skippedImageCount > 0 {
            NSSound.beep()
            DiagnosticsLogger.log(
                .chatView,
                level: .info,
                message: "Skipped dropped images beyond the attachment limit",
                metadata: [
                    "skippedImageCount": "\(selection.skippedImageCount)",
                    "limit": "\(ChatDraftContent.maximumImageCount)",
                ]
            )
        }
    }

    /// Attaches asynchronously loaded drop URLs within the composer's import session. Each drop
    /// counts as pending until it loads, so Send stays disabled while any drop is outstanding,
    /// and a result arriving after the session rotated is discarded.
    @discardableResult
    static func receiveDrop(
        loadFileURLs: @escaping @MainActor () async -> [URL],
        attachedFiles: Binding<[URL]>,
        pastedImages: Binding<[PastedImage]>,
        importSessionID: Binding<UUID>,
        pendingDropCount: Binding<Int>
    ) -> Task<Void, Never> {
        let sessionID = importSessionID.wrappedValue
        pendingDropCount.wrappedValue += 1
        return Task { @MainActor in
            let fileURLs = await loadFileURLs()
            pendingDropCount.wrappedValue = max(0, pendingDropCount.wrappedValue - 1)
            guard importSessionID.wrappedValue == sessionID else { return }
            // Read the count after loading: a paste may have finished in the meantime.
            attach(fileURLs, to: attachedFiles, pastedImageCount: pastedImages.wrappedValue.count)
        }
    }

    /// Loads file URLs from drop providers in their dropped order.
    static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var fileURLs: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let fileURL: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url)
                }
            }
            if let fileURL, fileURL.isFileURL {
                fileURLs.append(fileURL)
            }
        }
        return fileURLs
    }
}

/// Makes a whole chat screen a drop target for file attachments.
///
/// Dropped URLs load asynchronously, so a drop joins the composer's import session like a
/// paste: Send stays disabled while any drop loads, and a result arriving after Send is discarded.
private struct ChatAttachmentDropModifier: ViewModifier {
    @Binding var attachedFiles: [URL]
    @Binding var pastedImages: [PastedImage]
    @Binding var importSessionID: UUID
    @Binding var pendingDropCount: Int
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                ChatAttachmentDrop.receiveDrop(
                    loadFileURLs: { await ChatAttachmentDrop.fileURLs(from: providers) },
                    attachedFiles: $attachedFiles,
                    pastedImages: $pastedImages,
                    importSessionID: $importSessionID,
                    pendingDropCount: $pendingDropCount
                )
                return true
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: Spacing.CornerRadius.md)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .background(
                            Color.accentColor.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: Spacing.CornerRadius.md)
                        )
                        .overlay {
                            Label("Drop to attach", systemImage: "paperclip")
                                .font(Typography.body)
                                .padding(Spacing.sm)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .padding(Spacing.sm)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    /// Attaches files dropped anywhere on this view to the composer.
    func chatAttachmentDropTarget(
        attachedFiles: Binding<[URL]>,
        pastedImages: Binding<[PastedImage]>,
        importSessionID: Binding<UUID>,
        pendingDropCount: Binding<Int>
    ) -> some View {
        modifier(ChatAttachmentDropModifier(
            attachedFiles: attachedFiles,
            pastedImages: pastedImages,
            importSessionID: importSessionID,
            pendingDropCount: pendingDropCount
        ))
    }
}
#endif

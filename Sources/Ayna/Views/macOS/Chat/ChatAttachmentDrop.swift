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
private struct ChatAttachmentDropModifier: ViewModifier {
    @Binding var attachedFiles: [URL]
    let pastedImageCount: Int
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                let attachedFiles = $attachedFiles
                let pastedImageCount = pastedImageCount
                Task { @MainActor in
                    let fileURLs = await ChatAttachmentDrop.fileURLs(from: providers)
                    ChatAttachmentDrop.attach(fileURLs, to: attachedFiles, pastedImageCount: pastedImageCount)
                }
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
    func chatAttachmentDropTarget(attachedFiles: Binding<[URL]>, pastedImageCount: Int) -> some View {
        modifier(ChatAttachmentDropModifier(attachedFiles: attachedFiles, pastedImageCount: pastedImageCount))
    }
}
#endif

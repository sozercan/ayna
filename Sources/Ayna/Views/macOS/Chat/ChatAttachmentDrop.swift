// swiftformat:options --ifdef no-indent
#if os(macOS)

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum ChatAttachmentDrop {
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
            attach(fileURLs, to: attachedFiles, pastedImageCount: pastedImages.wrappedValue.count)
        }
    }

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

//
//  IOSMessageComposer.swift
//  ayna
//
//  Created on 11/24/25.
//

import os.log
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A reusable message composer component for iOS chat views.
/// Handles text input, file attachments, sending messages, and generation cancellation.
/// Uses spring animations for smooth height transitions as text expands.
struct IOSMessageComposer: View {
    @Binding var messageText: String
    @Binding var isGenerating: Bool
    @Binding var errorMessage: String?
    @Binding var attachedFiles: [URL]
    @Binding var attachedImages: [UIImage]

    /// Optional recovery suggestion for the current error
    var errorRecoverySuggestion: String?

    /// Optional retry action for failed messages
    var onRetry: (() -> Void)?

    let showAttachmentButton: Bool
    let onSend: () -> Void
    let onCancel: () -> Void
    let onFileAttachmentRequested: () -> Void
    let onPhotoAttachmentRequested: () -> Void

    /// Called when error is dismissed
    var onDismissError: (() -> Void)?

    /// Accessibility identifier prefix for this composer instance
    let identifierPrefix: String

    /// Whether to show the attachment source selection sheet
    @State private var showAttachmentSourceSheet = false

    init(
        messageText: Binding<String>,
        isGenerating: Binding<Bool>,
        errorMessage: Binding<String?>,
        attachedFiles: Binding<[URL]> = .constant([]),
        attachedImages: Binding<[UIImage]> = .constant([]),
        errorRecoverySuggestion: String? = nil,
        onRetry: (() -> Void)? = nil,
        showAttachmentButton: Bool = true,
        identifierPrefix: String = "chat.composer",
        onSend: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onDismissError: (() -> Void)? = nil,
        onFileAttachmentRequested: @escaping () -> Void = {},
        onPhotoAttachmentRequested: @escaping () -> Void = {}
    ) {
        _messageText = messageText
        _isGenerating = isGenerating
        _errorMessage = errorMessage
        _attachedFiles = attachedFiles
        _attachedImages = attachedImages
        self.errorRecoverySuggestion = errorRecoverySuggestion
        self.onRetry = onRetry
        self.showAttachmentButton = showAttachmentButton
        self.identifierPrefix = identifierPrefix
        self.onSend = onSend
        self.onCancel = onCancel
        self.onDismissError = onDismissError
        self.onFileAttachmentRequested = onFileAttachmentRequested
        self.onPhotoAttachmentRequested = onPhotoAttachmentRequested
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            // Error message display using ErrorBannerView
            if let errorMessage {
                ErrorBannerView(
                    message: errorMessage,
                    recoverySuggestion: errorRecoverySuggestion,
                    onRetry: onRetry,
                    onDismiss: {
                        self.errorMessage = nil
                        onDismissError?()
                    },
                    identifierPrefix: "\(identifierPrefix).error"
                )
                .padding(.horizontal)
            }

            // Attached files display
            if !attachedFiles.isEmpty || !attachedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.sm) {
                        ForEach(attachedFiles, id: \.self) { url in
                            attachmentChip(for: url)
                        }
                        ForEach(attachedImages.indices, id: \.self) { index in
                            imageAttachmentChip(for: attachedImages[index], at: index)
                        }
                    }
                    .padding(.horizontal)
                }
                .accessibilityIdentifier("\(identifierPrefix).attachmentsList")
            }

            // Input bar with material background
            HStack(alignment: .bottom, spacing: Spacing.md) {
                // Attachment button - meets 44pt touch target
                if showAttachmentButton {
                    Button(action: { showAttachmentSourceSheet = true }) {
                        Image(systemName: "plus")
                            .font(.system(size: Typography.IconSize.lg, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(minWidth: Spacing.minTouchTarget, minHeight: Spacing.minTouchTarget)
                    .background(Theme.backgroundSecondary)
                    .clipShape(Circle())
                    .accessibilityIdentifier("\(identifierPrefix).attachButton")
                    .confirmationDialog("Add Attachment", isPresented: $showAttachmentSourceSheet) {
                        Button {
                            onPhotoAttachmentRequested()
                        } label: {
                            Label("Photo Library", systemImage: "photo.on.rectangle")
                        }
                        .accessibilityIdentifier("\(identifierPrefix).attachPhotoButton")

                        Button {
                            onFileAttachmentRequested()
                        } label: {
                            Label("Choose File", systemImage: "folder")
                        }
                        .accessibilityIdentifier("\(identifierPrefix).attachFileButton")

                        Button("Cancel", role: .cancel) {}
                    }
                }

                // Text field container with smooth height animation
                HStack(alignment: .bottom) {
                    TextField("Ask anything", text: $messageText, axis: .vertical)
                        .lineLimit(1 ... 5)
                        .font(Typography.body)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm + 2)
                        .accessibilityIdentifier("\(identifierPrefix).textEditor")
                        .onSubmit {
                            if !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isGenerating {
                                handleSendOrCancel()
                            }
                        }
                        .submitLabel(.send)
                }
                .background(Theme.backgroundSecondary)
                .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.pill))
                // Smooth spring animation when height changes from multiline text
                .animation(Motion.springSnappy, value: messageText.contains("\n") || messageText.count > 40)

                // Send/Stop button - meets 44pt touch target
                if !messageText.isEmpty || isGenerating {
                    Button(action: handleSendOrCancel) {
                        Image(systemName: isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(isGenerating ? Theme.statusError : Theme.accent)
                            .symbolEffect(.pulse, options: .repeating, value: isGenerating)
                    }
                    .frame(minWidth: Spacing.minTouchTarget, minHeight: Spacing.minTouchTarget)
                    .accessibilityIdentifier("\(identifierPrefix).sendButton")
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, Spacing.sm)
        // Material background for blur effect - content scrolls underneath
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func attachmentChip(for url: URL) -> some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: "doc.fill")
                .font(Typography.caption)
            Text(url.lastPathComponent)
                .font(Typography.caption)
                .lineLimit(1)
            Button {
                attachedFiles.removeAll { $0 == url }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityIdentifier("\(identifierPrefix).attachment.remove.\(url.lastPathComponent)")
        }
        .padding(Spacing.xs)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))
        .accessibilityIdentifier("\(identifierPrefix).attachment.\(url.lastPathComponent)")
    }

    @ViewBuilder
    private func imageAttachmentChip(for image: UIImage, at index: Int) -> some View {
        HStack(spacing: Spacing.xxs) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text("Image \(index + 1)")
                .font(Typography.caption)
                .lineLimit(1)
            Button {
                attachedImages.remove(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityIdentifier("\(identifierPrefix).attachment.remove.image\(index)")
        }
        .padding(Spacing.xs)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))
        .accessibilityIdentifier("\(identifierPrefix).attachment.image\(index)")
    }

    private func handleSendOrCancel() {
        if isGenerating {
            // Use centralized haptic engine
            HapticEngine.cancelButtonTap()

            DiagnosticsLogger.log(
                .chatView,
                level: .info,
                message: "🛑 User requested generation cancellation"
            )
            onCancel()
        } else {
            // Use centralized haptic engine
            HapticEngine.sendButtonTap()

            DiagnosticsLogger.log(
                .chatView,
                level: .info,
                message: "📤 User sending message",
                metadata: ["textLength": "\(messageText.count)"]
            )
            onSend()
        }
    }
}

// MARK: - File Attachment Utilities

enum IOSFileAttachmentUtils {
    /// Returns the MIME type for a given file URL based on its extension.
    static func getMimeType(for url: URL) -> String {
        let pathExtension = url.pathExtension.lowercased()
        switch pathExtension {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "pdf":
            return "application/pdf"
        case "txt", "md":
            return "text/plain"
        case "json":
            return "application/json"
        default:
            return "application/octet-stream"
        }
    }

    /// Processes attached files into Message.FileAttachment array.
    /// Properly handles security-scoped resources with defer to prevent leaks.
    static func processAttachments(from urls: [URL]) -> (attachments: [Message.FileAttachment], errors: [String]) {
        var attachments: [Message.FileAttachment] = []
        var errors: [String] = []

        for url in urls {
            // Use defer to ensure resource is always released
            defer {
                url.stopAccessingSecurityScopedResource()
            }

            do {
                let data = try Data(contentsOf: url)
                attachments.append(Message.FileAttachment(
                    fileName: url.lastPathComponent,
                    mimeType: getMimeType(for: url),
                    data: data
                ))
                DiagnosticsLogger.log(
                    .chatView,
                    level: .info,
                    message: "📎 Processed attachment: \(url.lastPathComponent)",
                    metadata: ["size": "\(data.count)"]
                )
            } catch {
                let errorMsg = "Failed to read \(url.lastPathComponent): \(error.localizedDescription)"
                errors.append(errorMsg)
                DiagnosticsLogger.log(
                    .chatView,
                    level: .error,
                    message: "❌ \(errorMsg)"
                )
            }
        }

        return (attachments, errors)
    }

    /// Processes UIImage attachments from the photo library into Message.FileAttachment array.
    /// Compresses images to JPEG format for API compatibility.
    static func processImageAttachments(from images: [UIImage]) -> [Message.FileAttachment] {
        var attachments: [Message.FileAttachment] = []

        for (index, image) in images.enumerated() {
            // Compress to JPEG with reasonable quality for API upload
            // OpenAI recommends images under 20MB and low detail mode for smaller sizes
            guard let imageData = image.jpegData(compressionQuality: 0.8) else {
                DiagnosticsLogger.log(
                    .chatView,
                    level: .error,
                    message: "❌ Failed to convert image \(index + 1) to JPEG data"
                )
                continue
            }

            let fileName = "photo_\(index + 1).jpg"
            attachments.append(Message.FileAttachment(
                fileName: fileName,
                mimeType: "image/jpeg",
                data: imageData
            ))

            DiagnosticsLogger.log(
                .chatView,
                level: .info,
                message: "📷 Processed image attachment: \(fileName)",
                metadata: ["size": "\(imageData.count)", "originalSize": "\(image.size)"]
            )
        }

        return attachments
    }
}

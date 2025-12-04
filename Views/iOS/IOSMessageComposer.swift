//
//  IOSMessageComposer.swift
//  ayna
//
//  Created on 11/24/25.
//

import os.log
import SwiftUI
import UniformTypeIdentifiers

/// A reusable message composer component for iOS chat views.
/// Handles text input, file attachments, sending messages, and generation cancellation.
struct IOSMessageComposer: View {
    @Binding var messageText: String
    @Binding var isGenerating: Bool
    @Binding var errorMessage: String?
    @Binding var attachedFiles: [URL]

    let showAttachmentButton: Bool
    let onSend: () -> Void
    let onCancel: () -> Void
    let onAttachmentRequested: () -> Void

    /// Accessibility identifier prefix for this composer instance
    let identifierPrefix: String

    init(
        messageText: Binding<String>,
        isGenerating: Binding<Bool>,
        errorMessage: Binding<String?>,
        attachedFiles: Binding<[URL]> = .constant([]),
        showAttachmentButton: Bool = true,
        identifierPrefix: String = "chat.composer",
        onSend: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onAttachmentRequested: @escaping () -> Void = {}
    ) {
        _messageText = messageText
        _isGenerating = isGenerating
        _errorMessage = errorMessage
        _attachedFiles = attachedFiles
        self.showAttachmentButton = showAttachmentButton
        self.identifierPrefix = identifierPrefix
        self.onSend = onSend
        self.onCancel = onCancel
        self.onAttachmentRequested = onAttachmentRequested
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            // Error message display
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(Theme.statusError)
                    .font(Typography.caption)
                    .padding(.horizontal)
                    .accessibilityIdentifier("\(identifierPrefix).errorMessage")
            }

            // Attached files display
            if !attachedFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.sm) {
                        ForEach(attachedFiles, id: \.self) { url in
                            attachmentChip(for: url)
                        }
                    }
                    .padding(.horizontal)
                }
                .accessibilityIdentifier("\(identifierPrefix).attachmentsList")
            }

            // Input bar
            HStack(alignment: .bottom, spacing: Spacing.md) {
                // Attachment button
                if showAttachmentButton {
                    Button(action: onAttachmentRequested) {
                        Image(systemName: "plus")
                            .font(.system(size: Typography.IconSize.lg, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(Spacing.sm)
                            .background(Theme.backgroundSecondary)
                            .clipShape(Circle())
                    }
                    .padding(.bottom, 5)
                    .accessibilityIdentifier("\(identifierPrefix).attachButton")
                }

                // Text field container
                HStack(alignment: .bottom) {
                    TextField("Ask anything", text: $messageText, axis: .vertical)
                        .lineLimit(1 ... 5)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
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

                // Send/Stop button
                if !messageText.isEmpty || isGenerating {
                    Button(action: handleSendOrCancel) {
                        Image(systemName: isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(isGenerating ? Theme.statusError : Theme.accent)
                    }
                    .padding(.bottom, Spacing.xxxs)
                    .accessibilityIdentifier("\(identifierPrefix).sendButton")
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, Spacing.sm)
        .background(.bar)
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

    private func handleSendOrCancel() {
        if isGenerating {
            // Light haptic for cancel
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()

            DiagnosticsLogger.log(
                .chatView,
                level: .info,
                message: "🛑 User requested generation cancellation"
            )
            onCancel()
        } else {
            // Medium haptic for send
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()

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
}

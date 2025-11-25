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
        VStack(spacing: 8) {
            // Error message display
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal)
                    .accessibilityIdentifier("\(identifierPrefix).errorMessage")
            }

            // Attached files display
            if !attachedFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachedFiles, id: \.self) { url in
                            attachmentChip(for: url)
                        }
                    }
                    .padding(.horizontal)
                }
                .accessibilityIdentifier("\(identifierPrefix).attachmentsList")
            }

            // Input bar
            HStack(alignment: .bottom, spacing: 12) {
                // Attachment button
                if showAttachmentButton {
                    Button(action: onAttachmentRequested) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.gray)
                            .padding(8)
                            .background(Color(uiColor: .systemGray5))
                            .clipShape(Circle())
                    }
                    .padding(.bottom, 5)
                    .accessibilityIdentifier("\(identifierPrefix).attachButton")
                }

                // Text field container
                HStack(alignment: .bottom) {
                    TextField("Ask anything", text: $messageText, axis: .vertical)
                        .lineLimit(1 ... 5)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("\(identifierPrefix).textEditor")
                }
                .background(Color(uiColor: .systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 20))

                // Send/Stop button
                if !messageText.isEmpty || isGenerating {
                    Button(action: handleSendOrCancel) {
                        Image(systemName: isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(isGenerating ? .red : .blue)
                    }
                    .padding(.bottom, 2)
                    .accessibilityIdentifier("\(identifierPrefix).sendButton")
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func attachmentChip(for url: URL) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.fill")
                .font(.caption)
            Text(url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
            Button {
                attachedFiles.removeAll { $0 == url }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.gray)
            }
            .accessibilityIdentifier("\(identifierPrefix).attachment.remove.\(url.lastPathComponent)")
        }
        .padding(6)
        .background(Color(uiColor: .systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

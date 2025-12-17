//
//  ChatExporter.swift
//  ayna
//
//  Extracted from MacChatView.swift - Export helpers for conversations
//

import AppKit
import SwiftUI

/// Export format options for conversations
enum ExportFormat {
    case markdown
    case pdf
}

/// Helper for exporting conversations to various formats
@MainActor
enum ChatExportHelper {
    /// Export conversation to the specified format
    static func exportConversation(_ conversation: Conversation, format: ExportFormat) -> URL? {
        switch format {
        case .markdown:
            exportAsMarkdown(conversation)
        case .pdf:
            ConversationExporter.generatePDF(for: conversation)
        }
    }

    private static func exportAsMarkdown(_ conversation: Conversation) -> URL? {
        let content = ConversationExporter.generateMarkdown(for: conversation)
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "\(conversation.title.replacingOccurrences(of: " ", with: "_")).md"
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            DiagnosticsLogger.log(
                .chatView,
                level: .error,
                message: "❌ Failed to write markdown export: \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// Show the system share sheet for a URL
    static func showShareSheet(for url: URL) {
        let picker = NSSharingServicePicker(items: [url])
        DispatchQueue.main.async {
            if let window = NSApp.keyWindow, let contentView = window.contentView {
                picker.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)
            }
        }
    }
}

/// Helper to get MIME type from file URL
enum MIMETypeHelper {
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
        case "txt":
            return "text/plain"
        case "json":
            return "application/json"
        case "xml":
            return "application/xml"
        default:
            return "application/octet-stream"
        }
    }
}

//
//  ConversationExporter.swift
//  ayna
//
//  Created on 11/18/25.
//

import AppKit
import Foundation
import PDFKit
import SwiftUI

enum ConversationExporter {
    static func generateMarkdown(for conversation: Conversation) -> String {
        var markdown = "# \(conversation.title)\n\n"
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        markdown += "Date: \(dateFormatter.string(from: conversation.createdAt))\n"
        markdown += "Model: \(conversation.model)\n\n"
        markdown += "---\n\n"

        for message in conversation.messages {
            guard message.role != .system, message.role != .tool else { continue }

            let roleName = message.role == .user ? "User" : "Assistant"
            markdown += "### \(roleName)\n\n"

            if let attachments = message.attachments, !attachments.isEmpty {
                markdown += "*[Attachments: \(attachments.map(\.fileName).joined(separator: ", "))]*\n\n"
            }

            if !message.content.isEmpty {
                markdown += "\(message.content)\n\n"
            }

            if let reasoning = message.reasoning {
                markdown +=
                    "> **Reasoning:**\n> \(reasoning.replacingOccurrences(of: "\n", with: "\n> "))\n\n"
            }

            markdown += "---\n\n"
        }

        return markdown
    }

    @MainActor
    static func generatePDF(for conversation: Conversation) -> URL? {
        // We'll use a temporary URL for the PDF
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "\(conversation.title.replacingOccurrences(of: " ", with: "_")).pdf"
        let pdfURL = tempDir.appendingPathComponent(fileName)

        // Page setup
        let pageWidth: CGFloat = 612 // 8.5 inches * 72 dpi
        let pageHeight: CGFloat = 792 // 11 inches * 72 dpi
        let margin: CGFloat = 50
        let contentWidth = pageWidth - (margin * 2)
        let contentHeight = pageHeight - (margin * 2)

        // Text attributes
        let titleFont = NSFont.boldSystemFont(ofSize: 24)
        let headerFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let roleFont = NSFont.boldSystemFont(ofSize: 14)
        let bodyFont = NSFont.systemFont(ofSize: 12)

        let titleAttributes: [NSAttributedString.Key: Any] = [.font: titleFont]
        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: headerFont, .foregroundColor: NSColor.secondaryLabelColor
        ]
        let userRoleAttributes: [NSAttributedString.Key: Any] = [
            .font: roleFont, .foregroundColor: NSColor.systemBlue
        ]
        let assistantRoleAttributes: [NSAttributedString.Key: Any] = [
            .font: roleFont, .foregroundColor: NSColor.systemGreen
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [.font: bodyFont]

        // Create attributed string for the entire content
        let fullContent = NSMutableAttributedString()

        // Title
        fullContent.append(
            NSAttributedString(string: conversation.title + "\n\n", attributes: titleAttributes))

        // Metadata
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let metaText =
            "Date: \(dateFormatter.string(from: conversation.createdAt)) • Model: \(conversation.model)\n\n"
        fullContent.append(NSAttributedString(string: metaText, attributes: headerAttributes))

        // Messages
        for message in conversation.messages {
            guard message.role != .system, message.role != .tool else { continue }

            // Role
            let roleName = message.role == .user ? "User" : "Assistant"
            let roleAttributes = message.role == .user ? userRoleAttributes : assistantRoleAttributes
            fullContent.append(NSAttributedString(string: roleName + "\n", attributes: roleAttributes))

            // Content
            var content = message.content
            if let reasoning = message.reasoning {
                content += "\n\n[Reasoning: \(reasoning)]"
            }

            fullContent.append(NSAttributedString(string: content + "\n\n", attributes: bodyAttributes))
        }

        // Create PDF Context
        guard let pdfContext = CGContext(pdfURL as CFURL, mediaBox: nil, nil) else {
            return nil
        }

        let framesetter = CTFramesetterCreateWithAttributedString(fullContent)
        var currentTextRange = CFRange(location: 0, length: 0)
        let textLength = fullContent.length

        while currentTextRange.location < textLength {
            pdfContext.beginPDFPage(nil)

            // Core Text coordinates are bottom-up, so we need to flip the context
            // However, we need to be careful with the path.
            // Let's define the text frame rect.

            let path = CGMutablePath()
            // In Core Text, (0,0) is bottom-left.
            // We want to draw from top-left of the page, which is (margin, pageHeight - margin).
            // But since we flip the context, we can draw in a flipped coordinate system?
            // Standard way:
            // 1. Flip context.
            // 2. Define rect in flipped coordinates.

            pdfContext.saveGState()

            // Flip the context so (0,0) is bottom-left (standard PDF/Quartz)
            // Actually, PDF context is already bottom-left origin.
            // But CTFramesetter expects standard Quartz coordinates.

            // Let's define the rect where text goes.
            // Bottom-left of text box is (margin, margin). Top-right is (pageWidth - margin, pageHeight - margin).
            let textRect = CGRect(x: margin, y: margin, width: contentWidth, height: contentHeight)
            path.addRect(textRect)

            let frame = CTFramesetterCreateFrame(
                framesetter, CFRange(location: currentTextRange.location, length: 0), path, nil
            )
            let frameRange = CTFrameGetVisibleStringRange(frame)

            CTFrameDraw(frame, pdfContext)

            pdfContext.restoreGState()

            currentTextRange.location += frameRange.length
            pdfContext.endPDFPage()
        }

        pdfContext.closePDF()
        return pdfURL
    }
}

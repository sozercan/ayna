// swiftformat:options --ifdef no-indent

#if os(macOS)
import AppKit

typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#elseif os(iOS)
import UIKit

typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#endif
import Foundation
import SwiftUI
#if os(macOS) || os(iOS)
import PDFKit
#endif

enum ConversationExporter {
    static func generateMarkdown(for conversation: Conversation) -> String {
        var markdown = "# \(conversation.title)\n\n"
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        markdown += "Date: \(dateFormatter.string(from: conversation.createdAt))\n"
        markdown += "Model: \(conversation.model)\n\n"
        markdown += "---\n\n"

        for message in conversation.getEffectiveHistory() {
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

    #if os(macOS) || os(iOS)
    @MainActor
    static func generatePDF(for conversation: Conversation) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let sanitized = conversation.title
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "..", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
        let fileName = sanitized.isEmpty ? "conversation.pdf" : "\(sanitized).pdf"
        let pdfURL = tempDir.appendingPathComponent(fileName)

        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 50
        let contentWidth = pageWidth - (margin * 2)
        let contentHeight = pageHeight - (margin * 2)

        let titleFont = PlatformFont.boldSystemFont(ofSize: 24)
        let headerFont = PlatformFont.systemFont(ofSize: 12, weight: .medium)
        let roleFont = PlatformFont.boldSystemFont(ofSize: 14)
        let bodyFont = PlatformFont.systemFont(ofSize: 12)

        let titleAttributes: [NSAttributedString.Key: Any] = [.font: titleFont]
        let secondaryColor: PlatformColor = {
            #if os(macOS)
            PlatformColor.secondaryLabelColor
            #else
            PlatformColor.secondaryLabel
            #endif
        }()

        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: headerFont, .foregroundColor: secondaryColor
        ]
        let userRoleAttributes: [NSAttributedString.Key: Any] = [
            .font: roleFont, .foregroundColor: PlatformColor.systemBlue
        ]
        let assistantRoleAttributes: [NSAttributedString.Key: Any] = [
            .font: roleFont, .foregroundColor: PlatformColor.systemGreen
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [.font: bodyFont]

        let fullContent = NSMutableAttributedString()

        fullContent.append(
            NSAttributedString(string: conversation.title + "\n\n", attributes: titleAttributes)
        )

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let metaText =
            "Date: \(dateFormatter.string(from: conversation.createdAt)) • Model: \(conversation.model)\n\n"
        fullContent.append(NSAttributedString(string: metaText, attributes: headerAttributes))

        for message in conversation.getEffectiveHistory() {
            guard message.role != .system, message.role != .tool else { continue }

            let roleName = message.role == .user ? "User" : "Assistant"
            let roleAttributes = message.role == .user ? userRoleAttributes : assistantRoleAttributes
            fullContent.append(NSAttributedString(string: roleName + "\n", attributes: roleAttributes))

            var content = message.content
            if let reasoning = message.reasoning {
                content += "\n\n[Reasoning: \(reasoning)]"
            }

            fullContent.append(NSAttributedString(string: content + "\n\n", attributes: bodyAttributes))
        }

        guard let pdfContext = CGContext(pdfURL as CFURL, mediaBox: nil, nil) else {
            DiagnosticsLogger.log(.app, level: .error, message: "Failed to create PDF context")
            return nil
        }

        let framesetter = CTFramesetterCreateWithAttributedString(fullContent)
        var currentTextRange = CFRange(location: 0, length: 0)
        let textLength = fullContent.length

        while currentTextRange.location < textLength {
            pdfContext.beginPDFPage(nil)

            let path = CGMutablePath()

            pdfContext.saveGState()

            let textRect = CGRect(x: margin, y: margin, width: contentWidth, height: contentHeight)
            path.addRect(textRect)

            let frame = CTFramesetterCreateFrame(
                framesetter, CFRange(location: currentTextRange.location, length: 0), path, nil
            )
            let frameRange = CTFrameGetVisibleStringRange(frame)
            if frameRange.length == 0 { break }

            CTFrameDraw(frame, pdfContext)

            pdfContext.restoreGState()

            currentTextRange.location += frameRange.length
            pdfContext.endPDFPage()
        }

        pdfContext.closePDF()
        return pdfURL
    }
    #endif
}

// swiftformat:options --ifdef no-indent
#if os(macOS)
//
//  MIMETypeHelper.swift
//  ayna
//
//  Maps attachment file extensions to MIME types.
//

import Foundation

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
#endif

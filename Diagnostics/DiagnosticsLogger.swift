//
//  DiagnosticsLogger.swift
//  ayna
//
//  Created on 11/14/25.
//

import Foundation
import os.log

enum DiagnosticsCategory: String, CaseIterable, Codable {
    case app = "App"
    case openAIService = "OpenAIService"
    case mcpServerManager = "MCPServerManager"
    case mcpService = "MCPService"
    case aiKitService = "AIKitService"
    case appleIntelligence = "AppleIntelligenceService"
    case encryptedStore = "EncryptedConversationStore"
    case keychain = "KeychainStorage"
    case conversationManager = "ConversationManager"
    case chatView = "ChatView"
    case contentView = "ContentView"
    case llamaCppService = "LlamaCppService"
}

enum BreadcrumbLevel: String, Codable {
    case debug
    case info
    case notice
    case warning
    case error
    case fault
}

struct Breadcrumb: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let category: DiagnosticsCategory
    let level: BreadcrumbLevel
    let message: String
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: DiagnosticsCategory,
        level: BreadcrumbLevel,
        message: String,
        metadata: [String: String],
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.message = message
        self.metadata = metadata
    }
}

final class BreadcrumbStore: @unchecked Sendable {
    static let shared = BreadcrumbStore()

    private let maxEntries = 200
    private let queue = DispatchQueue(label: "com.sertacozercan.ayna.breadcrumbs", qos: .utility)
    private let storageURL: URL
    private var entries: [Breadcrumb] = []

    private init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = appSupport.appendingPathComponent("Ayna", isDirectory: true)

        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        storageURL = directory.appendingPathComponent("breadcrumbs.json")

        if let data = try? Data(contentsOf: storageURL),
           let decoded = try? JSONDecoder().decode([Breadcrumb].self, from: data)
        {
            entries = Array(decoded.suffix(maxEntries))
        }
    }

    func record(
        category: DiagnosticsCategory,
        level: BreadcrumbLevel,
        message: String,
        metadata: [String: String],
    ) {
        queue.async {
            let breadcrumb = Breadcrumb(category: category, level: level, message: message, metadata: metadata)
            self.entries.append(breadcrumb)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
            self.persistLocked()
        }
    }

    func latest(limit: Int? = nil) -> [Breadcrumb] {
        queue.sync {
            let snapshot = entries
            if let limit, limit < snapshot.count {
                return Array(snapshot.suffix(limit))
            }
            return snapshot
        }
    }

    private func persistLocked() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            os_log("Failed to persist breadcrumbs: %{public}@", log: .default, type: .error, error.localizedDescription)
        }
    }
}

enum DiagnosticsLogger {
    private static let subsystem = "com.sertacozercan.ayna"
    private static let loggers: [DiagnosticsCategory: Logger] = {
        var dictionary: [DiagnosticsCategory: Logger] = [:]
        for category in DiagnosticsCategory.allCases {
            dictionary[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        return dictionary
    }()

    static func log(
        _ category: DiagnosticsCategory,
        level: OSLogType = .default,
        message: String,
        metadata: [String: String] = [:],
    ) {
        guard let logger = loggers[category] else { return }

        if metadata.isEmpty {
            logger.log(level: level, "\(message, privacy: .public)")
        } else {
            let metaString = metadata
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            logger.log(level: level, "\(message, privacy: .public) [\(metaString, privacy: .public)]")
        }

        BreadcrumbStore.shared.record(
            category: category,
            level: level.breadcrumbLevel,
            message: message,
            metadata: metadata,
        )
    }
}

private extension OSLogType {
    var breadcrumbLevel: BreadcrumbLevel {
        switch self {
        case .debug:
            .debug
        case .info:
            .info
        case .default:
            .notice
        case .error:
            .error
        case .fault:
            .fault
        default:
            .notice
        }
    }
}

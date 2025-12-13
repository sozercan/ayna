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
    case attachmentStorage = "AttachmentStorage"
    case watchConnectivity = "WatchConnectivity"
    case attachFromApp = "AttachFromApp"
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

    nonisolated init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: DiagnosticsCategory,
        level: BreadcrumbLevel,
        message: String,
        metadata: [String: String]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.message = message
        self.metadata = metadata
    }
}

actor BreadcrumbStore {
    static let shared = BreadcrumbStore()

    private let maxEntries = 200
    private let persistDebounce: Duration = .seconds(1)
    private let storageURL: URL
    private var entries: [Breadcrumb] = []
    private var persistTask: Task<Void, Never>?

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
        metadata: [String: String]
    ) {
        let breadcrumb = Breadcrumb(category: category, level: level, message: message, metadata: metadata)
        entries.append(breadcrumb)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        schedulePersist()
    }

    func latest(limit: Int? = nil) -> [Breadcrumb] {
        if let limit, limit < entries.count {
            return Array(entries.suffix(limit))
        }
        return entries
    }

    // MARK: - Private

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [storageURL, persistDebounce] in
            do {
                try await Task.sleep(for: persistDebounce)
            } catch {
                return
            }
            await BreadcrumbStore.shared.persistNow(storageURL: storageURL)
        }
    }

    private func persistNow(storageURL: URL) {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            os_log("Failed to persist breadcrumbs: %{public}@", log: .default, type: .error, error.localizedDescription)
        }
    }
}

final class LogThrottle: @unchecked Sendable {
    nonisolated static let shared = LogThrottle()

    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var lastLogByKey: [String: Date] = [:]

    nonisolated func shouldLog(key: String, interval: TimeInterval) -> Bool {
        let now = Date()

        lock.lock()
        defer { lock.unlock() }

        if let last = lastLogByKey[key], now.timeIntervalSince(last) < interval {
            return false
        }

        lastLogByKey[key] = now
        return true
    }
}

enum DiagnosticsLogger {
    private nonisolated static let subsystem = "com.sertacozercan.ayna"
    private nonisolated static let loggers: [DiagnosticsCategory: Logger] = {
        var dictionary: [DiagnosticsCategory: Logger] = [:]
        for category in DiagnosticsCategory.allCases {
            dictionary[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        return dictionary
    }()

    nonisolated static func log(
        _ category: DiagnosticsCategory,
        level: OSLogType = .default,
        message: String,
        metadata: [String: String] = [:]
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

        // Persisting high-frequency logs (e.g. streaming debug) can be noisy and expensive.
        // By default, we only record breadcrumbs for info+.
        if level != .debug {
            Task {
                await BreadcrumbStore.shared.record(
                    category: category,
                    level: level.breadcrumbLevel,
                    message: message,
                    metadata: metadata
                )
            }
        }
    }

    nonisolated static func logThrottled(
        _ category: DiagnosticsCategory,
        level: OSLogType = .default,
        throttleKey: String,
        interval: TimeInterval,
        message: String,
        metadata: [String: String] = [:]
    ) {
        let key = "\(category.rawValue)|\(level.breadcrumbLevel.rawValue)|\(throttleKey)"
        guard LogThrottle.shared.shouldLog(key: key, interval: interval) else { return }
        log(category, level: level, message: message, metadata: metadata)
    }
}

private extension OSLogType {
    nonisolated var breadcrumbLevel: BreadcrumbLevel {
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

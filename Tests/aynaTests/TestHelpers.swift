@testable import Ayna
import Foundation
import Security
import Testing

// MARK: - CustomTestStringConvertible Extensions

/// Provides better test failure diagnostics per Swift Testing Playbook Section 10
extension Conversation: @retroactive CustomTestStringConvertible {
    public var testDescription: String {
        "Conversation(\(id.uuidString.prefix(8))..., title: \"\(title)\", messages: \(messages.count), model: \(model))"
    }
}

extension Message: @retroactive CustomTestStringConvertible {
    public var testDescription: String {
        let contentPreview = content.prefix(30)
        let suffix = content.count > 30 ? "..." : ""
        return "Message(\(role.rawValue), \"\(contentPreview)\(suffix)\")"
    }
}

// MARK: - In-Memory Keychain Storage

final class InMemoryKeychainStorage: KeychainStoring, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    func setString(_ value: String, for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let data = value.data(using: .utf8) else {
            throw KeychainStorageError.unexpectedStatus(errSecParam)
        }
        storage[key] = data
    }

    func string(for key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = storage[key] else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setData(_ data: Data, for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = data
    }

    func data(for key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func removeValue(for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = nil
    }
}

enum TestHelpers {
    static func makeTemporaryDirectory(name: String = UUID().uuidString) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func sampleConversation(id: UUID = UUID(), title: String = "Sample", model: String = "gpt-4o") -> Conversation {
        var conversation = Conversation(id: id, title: title, model: model)
        conversation.addMessage(Message(role: .user, content: "Hello"))
        conversation.addMessage(Message(role: .assistant, content: "Hi there"))
        return conversation
    }

    static func makeTestStore(
        directory: URL,
        keyIdentifier: String = UUID().uuidString,
        keychain: KeychainStoring = InMemoryKeychainStorage()
    ) -> EncryptedConversationStore {
        EncryptedConversationStore(
            directoryURL: directory, keyIdentifier: keyIdentifier, keychain: keychain
        )
    }
}

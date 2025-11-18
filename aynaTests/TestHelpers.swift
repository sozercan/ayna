@testable import Ayna
import Foundation
import Security
import XCTest

final class InMemoryKeychainStorage: KeychainStoring {
    private var storage: [String: Data] = [:]

    func setString(_ value: String, for key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainStorageError.unexpectedStatus(errSecParam)
        }
        storage[key] = data
    }

    func string(for key: String) throws -> String? {
        guard let data = storage[key] else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setData(_ data: Data, for key: String) throws {
        storage[key] = data
    }

    func data(for key: String) throws -> Data? {
        storage[key]
    }

    func removeValue(for key: String) throws {
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
        let fileURL = directory.appendingPathComponent("conversations.enc")
        return EncryptedConversationStore(fileURL: fileURL, keyIdentifier: keyIdentifier, keychain: keychain)
    }
}

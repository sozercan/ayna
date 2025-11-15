//
//  EncryptedConversationStore.swift
//  ayna
//
//  Created on 11/14/25.
//

import CryptoKit
import Foundation

final class EncryptedConversationStore {
  static let shared = EncryptedConversationStore()

  private let fileURL: URL
  private let keyIdentifier = "conversation_encryption_key"
  private let keychain = KeychainStorage.shared

  private init() {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let directory = appSupport.appendingPathComponent("Ayna", isDirectory: true)

    if !FileManager.default.fileExists(atPath: directory.path) {
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    self.fileURL = directory.appendingPathComponent("conversations.enc")
  }

  func loadConversations() throws -> [Conversation] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return []
    }

    let encryptedData = try Data(contentsOf: fileURL)
    let box = try AES.GCM.SealedBox(combined: encryptedData)
    let plaintext = try AES.GCM.open(box, using: encryptionKey())
    return try JSONDecoder().decode([Conversation].self, from: plaintext)
  }

  func save(_ conversations: [Conversation]) throws {
    let encoded = try JSONEncoder().encode(conversations)
    let sealed = try AES.GCM.seal(encoded, using: encryptionKey())
    guard let combined = sealed.combined else {
      throw KeychainStorageError.unexpectedStatus(errSecParam)
    }
    try combined.write(to: fileURL, options: .atomic)
  }

  func clear() throws {
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try FileManager.default.removeItem(at: fileURL)
    }
  }

  private func encryptionKey() throws -> SymmetricKey {
    if let existing = try keychain.data(for: keyIdentifier) {
      return SymmetricKey(data: existing)
    }

    let newKey = SymmetricKey(size: .bits256)
    let keyData = newKey.withUnsafeBytes { Data($0) }
    try keychain.setData(keyData, for: keyIdentifier)
    return newKey
  }
}

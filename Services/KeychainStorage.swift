//
//  KeychainStorage.swift
//  ayna
//
//  Created on 11/14/25.
//

import Foundation
import Security

enum KeychainStorageError: LocalizedError {
  case unexpectedStatus(OSStatus)

  var errorDescription: String? {
    switch self {
    case .unexpectedStatus(let status):
      if let message = SecCopyErrorMessageString(status, nil) as String? {
        return message
      }
      return "Keychain operation failed with status: \(status)"
    }
  }
}

final class KeychainStorage {
  static let shared = KeychainStorage()

  private let serviceIdentifier = "com.sertacozercan.ayna"
  private init() {}

  func setString(_ value: String, for key: String) throws {
    guard let data = value.data(using: .utf8) else {
      throw KeychainStorageError.unexpectedStatus(errSecParam)
    }
    try setData(data, for: key)
  }

  func string(for key: String) throws -> String? {
    guard let data = try data(for: key) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  func setData(_ data: Data, for key: String) throws {
    var query = baseQuery(for: key)
    let updateAttributes = [kSecValueData as String: data]
    let status = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)

    if status == errSecItemNotFound {
      query[kSecValueData as String] = data
      query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let addStatus = SecItemAdd(query as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw KeychainStorageError.unexpectedStatus(addStatus)
      }
      return
    }

    guard status == errSecSuccess else {
      throw KeychainStorageError.unexpectedStatus(status)
    }
  }

  func data(for key: String) throws -> Data? {
    var query = baseQuery(for: key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)

    guard status != errSecItemNotFound else { return nil }
    guard status == errSecSuccess else {
      throw KeychainStorageError.unexpectedStatus(status)
    }

    guard let data = item as? Data else { return nil }
    return data
  }

  func removeValue(for key: String) throws {
    let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainStorageError.unexpectedStatus(status)
    }
  }

  private func baseQuery(for key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceIdentifier,
      kSecAttrAccount as String: key
    ]
  }
}

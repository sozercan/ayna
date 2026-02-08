//
//  KeychainStorage.swift
//  ayna
//
//  Created on 11/14/25.
//

import Foundation
import os.log
import Security

protocol KeychainStoring: Sendable {
    nonisolated func setString(_ value: String, for key: String) throws
    nonisolated func string(for key: String) throws -> String?
    nonisolated func setData(_ data: Data, for key: String) throws
    nonisolated func data(for key: String) throws -> Data?
    nonisolated func removeValue(for key: String) throws
}

enum KeychainStorageError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return message
            }
            return "Keychain operation failed with status: \(status)"
        }
    }
}

final class KeychainStorage: Sendable {
    nonisolated static let shared = KeychainStorage()

    private let serviceIdentifier = "com.sertacozercan.ayna"
    // Note: Keychain access groups require a paid Apple Developer account.
    // For free accounts, keychain items are tied to the app's code signature
    // and won't persist across rebuilds. See AIService for file-based fallback.

    private init() {}

    private nonisolated func log(
        _ message: String,
        level: OSLogType = .default,
        metadata: [String: String] = [:]
    ) {
        DiagnosticsLogger.log(.keychain, level: level, message: message, metadata: metadata)
    }

    nonisolated func setString(_ value: String, for key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainStorageError.unexpectedStatus(errSecParam)
        }
        try setData(data, for: key)
    }

    nonisolated func string(for key: String) throws -> String? {
        guard let data = try data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated func setData(_ data: Data, for key: String) throws {
        // First, try to delete any existing item to avoid conflicts from previous app signatures
        // This is a workaround for free developer accounts where keychain items may be
        // inaccessible after rebuilding due to code signature changes
        let deleteStatus = SecItemDelete(baseQuery(for: key) as CFDictionary)
        if deleteStatus != errSecSuccess, deleteStatus != errSecItemNotFound {
            log(
                "Note: Could not delete existing keychain item (may be from different signature)",
                level: .info,
                metadata: ["status": "\(deleteStatus)", "key": key, "statusMessage": statusMessage(deleteStatus)]
            )
        }

        // Now add the new item
        var query = baseQuery(for: key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            log(
                "Failed to add keychain item",
                level: .error,
                metadata: ["status": "\(addStatus)", "key": key, "statusMessage": statusMessage(addStatus)]
            )
            throw KeychainStorageError.unexpectedStatus(addStatus)
        }

        log(
            "Successfully stored keychain item",
            level: .info,
            metadata: ["key": key, "dataSize": "\(data.count)"]
        )
    }

    nonisolated func data(for key: String) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            log(
                "Keychain item not found",
                level: .info,
                metadata: ["key": key]
            )
            return nil
        }

        guard status == errSecSuccess else {
            log(
                "Failed to read keychain item",
                level: .error,
                metadata: ["status": "\(status)", "key": key, "statusMessage": statusMessage(status)]
            )
            throw KeychainStorageError.unexpectedStatus(status)
        }

        guard let data = item as? Data else {
            log(
                "Keychain item found but data is nil",
                level: .error,
                metadata: ["key": key]
            )
            return nil
        }

        log(
            "Successfully read keychain item",
            level: .debug,
            metadata: ["key": key, "dataSize": "\(data.count)"]
        )
        return data
    }

    private nonisolated func statusMessage(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "Unknown error"
    }

    nonisolated func removeValue(for key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            log(
                "Failed to remove keychain item",
                level: .error,
                metadata: ["status": "\(status)", "key": key]
            )
            throw KeychainStorageError.unexpectedStatus(status)
        }
    }

    private nonisolated func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: key
            // iCloud sync disabled for free developer account
            // kSecAttrSynchronizable as String: kCFBooleanTrue!
        ]
        // Note: Access group for shared keychain requires paid developer account.
        // Uncomment below if using App Groups:
        // #if os(iOS) || os(watchOS)
        // query[kSecAttrAccessGroup as String] = accessGroup
        // #endif
    }
}

extension KeychainStorage: KeychainStoring {}

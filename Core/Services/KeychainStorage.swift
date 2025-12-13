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
    // Note: Shared keychain access groups require a paid developer account.
    // For free accounts, each app uses its own keychain and syncs via WatchConnectivity.
    // Uncomment below if using a paid account with App Groups capability:
    // #if os(iOS) || os(watchOS)
    // private let accessGroup = "group.com.sertacozercan.ayna"
    // #endif
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
        var query = baseQuery(for: key)
        let updateAttributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)

        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                log(
                    "Failed to add keychain item",
                    level: .error,
                    metadata: ["status": "\(addStatus)", "key": key]
                )
                throw KeychainStorageError.unexpectedStatus(addStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            log(
                "Failed to update keychain item",
                level: .error,
                metadata: ["status": "\(status)", "key": key]
            )
            throw KeychainStorageError.unexpectedStatus(status)
        }
    }

    nonisolated func data(for key: String) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else {
            log(
                "Failed to read keychain item",
                level: .error,
                metadata: ["status": "\(status)", "key": key]
            )
            throw KeychainStorageError.unexpectedStatus(status)
        }

        guard let data = item as? Data else { return nil }
        return data
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
        let query: [String: Any] = [
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
        return query
    }
}

extension KeychainStorage: KeychainStoring {}

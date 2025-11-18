import Foundation
import Security

/// Lightweight in-memory implementation used when running UI tests so we never touch the real Keychain.
final class EphemeralKeychainStorage: KeychainStoring {
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

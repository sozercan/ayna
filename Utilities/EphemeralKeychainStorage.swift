import Foundation
import Security

/// Lightweight in-memory implementation used when running UI tests so we never touch the real Keychain.
final class EphemeralKeychainStorage: KeychainStoring, @unchecked Sendable {
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

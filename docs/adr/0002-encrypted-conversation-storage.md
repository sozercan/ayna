# ADR-0002: Encrypted Conversation Storage

**Date**: 2024-12-01  
**Status**: Accepted  
**Context**: Secure persistence of user conversations containing potentially sensitive data  

## Context

Ayna stores conversation history locally for user convenience. These conversations may contain:

- Personal information shared with AI
- API responses with sensitive content
- Business or professional discussions
- Code snippets and technical details

We needed a storage solution that:
1. Protects data at rest
2. Works across macOS, iOS, and watchOS
3. Allows efficient querying and loading
4. Handles migration and versioning

## Decision

Implement encrypted JSON storage with the following architecture:

### 1. EncryptedConversationStore

A dedicated store that handles encryption/decryption transparently:

```swift
@MainActor
final class EncryptedConversationStore {
    func save(_ conversation: Conversation) async throws
    func load(id: UUID) async throws -> Conversation?
    func loadAll() async throws -> [Conversation]
    func delete(id: UUID) async throws
}
```

### 2. Encryption Strategy

- Use `CryptoKit` for encryption (AES-GCM)
- Generate per-device encryption key stored in Keychain
- Each conversation encrypted individually
- Metadata (titles, dates) may be stored separately for list display

### 3. File Structure

```
~/Library/Application Support/Ayna/
├── conversations/
│   ├── {uuid}.encrypted    # Encrypted conversation JSON
│   └── ...
└── metadata.json           # Index for quick list loading
```

### 4. ConversationPersistenceCoordinator

Orchestrates save/load operations with debouncing:

```swift
@MainActor @Observable
final class ConversationPersistenceCoordinator {
    func saveConversation(_ conversation: Conversation)  // Debounced
    func loadConversations() async throws -> [Conversation]
    func deleteConversation(id: UUID) async throws
}
```

## Consequences

### Positive

1. **Privacy**: Conversations encrypted at rest
2. **Portability**: JSON format is human-readable when decrypted
3. **Platform support**: CryptoKit works on all Apple platforms
4. **Keychain integration**: Encryption key protected by system security
5. **Granular access**: Individual conversations can be loaded/saved

### Negative

1. **Performance overhead**: Encryption/decryption adds latency
2. **Key management**: Lost Keychain = lost conversations
3. **No cloud sync**: Encryption tied to device-specific key
4. **Search limitations**: Cannot search encrypted content without loading

### Neutral

1. **Migration path**: JSON allows schema evolution
2. **Backup considerations**: Encrypted files can be backed up but not read elsewhere
3. **Debugging complexity**: Cannot inspect files directly

## Alternatives Considered

### 1. SQLite with SQLCipher
- **Pros**: Better query performance, battle-tested encryption
- **Cons**: Third-party dependency, more complex setup

### 2. Core Data with Data Protection
- **Pros**: Apple-native, automatic sync potential
- **Cons**: Heavier framework, less control over encryption

### 3. Plain JSON (no encryption)
- **Pros**: Simpler implementation, easier debugging
- **Cons**: Privacy concerns, not acceptable for sensitive data

## References

- [Core/Services/EncryptedConversationStore.swift](../../Core/Services/EncryptedConversationStore.swift)
- [Core/Services/ConversationPersistenceCoordinator.swift](../../Core/Services/ConversationPersistenceCoordinator.swift)
- [Core/Services/KeychainStorage.swift](../../Core/Services/KeychainStorage.swift)

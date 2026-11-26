# ADR-0010: Credential, Diagnostics Privacy, and Storage Environment Isolation

**Date**: 2026-11-26  
**Status**: Accepted  
**Context**: Ayna runs across signed app bundles, unsigned SwiftPM/dev launches, unit tests, and UI tests, while storing sensitive API keys, encrypted conversations, attachments, Spotlight entries, and diagnostics.

## Context

On macOS without paid Keychain access groups, Keychain items are tied to the app's code signature. Unsigned SwiftPM binaries, dev builds, and test runners sharing the production Keychain service or Application Support directory trigger macOS Keychain ACL prompts and risk corrupting or deleting production user data. In addition, metadata-first conversation loading, Spotlight indexing, and diagnostics logging must preserve privacy and never silently overwrite durable user data.

## Decision

### 1. Environment-Isolated Keychain & Storage Namespaces
- `RuntimeEnvironment` classifies launches into `production`, `dev`, `tests`, and `ui-tests`.
- Tests and UI tests use `EphemeralKeychainStorage` (in-memory) so test runners never touch or prompt for macOS Keychain items.
- Unsigned SwiftPM/dev launches use a separate, stable Keychain service identifier and per-environment Application Support subdirectories (`AttachmentStorage`, `MCPProcessTracker`) so dev/test cleanup can never reach production credentials, attachments, or PID files.

### 2. Credential Isolation & Non-Destructive Keychain Loading
- `AIService` tracks whether API keys loaded cleanly from Keychain during initialization; a Keychain read failure prevents subsequent writes from overwriting valid stored credentials (whereas an empty Keychain on first launch is a valid state, not a failure).
- Requests only ever send the selected model's own API key; another model's key never makes a model usable.
- OpenAI-hosted and Azure OpenAI endpoints require API keys; other custom OpenAI-compatible endpoints may omit provider auth to support local or network-authenticated servers (`OpenAIEndpointResolver`).

### 3. Diagnostics Privacy & Secret Redaction
- `DiagnosticsLogger` keeps recent breadcrumbs strictly in memory because metadata can contain file paths, shell commands, and error text. Legacy plaintext `breadcrumbs.json` files from earlier versions are actively deleted on startup.
- OSLog metadata uses `privacy: .private` so sensitive payloads are redacted unless a debugger is attached.
- All user-facing error strings pass through `ErrorPresenter` token/key redaction because upstream providers (such as OpenAI) can echo partial API keys in invalid-key error responses.

### 4. Metadata-First Persistence, Attachments & Spotlight Reconciliation
- `AttachmentStorage` stores message attachments out-of-band on disk to keep encrypted conversation records small. Legacy metadata sidecars written before attachment paths were recorded are backfilled once from the full record so deleting an unopened conversation can still garbage-collect its attachment files (`ConversationMetadata`).
- `EncryptedConversationStore` deletes the plaintext search index entry **before** deleting the authoritative encrypted conversation file so indexed text cannot outlive the record.
- `ConversationPersistenceCoordinator`'s compatibility API intentionally erases the store's concrete error type across the coordinator boundary.
- `ConversationManager` maintains a `durableDiskBaseline` to distinguish persisted disk state from unsaved in-memory edits:
  - Late-landing durable saves after a delete or clear never restore a conversation or its summary.
  - Edits to metadata-only conversations hydrate full message history first (`loadFullHistoryBeforeEdit`) so saving never overwrites history with an empty message list.
  - User-initiated reloads preserve conversations with active replies or unsaved in-memory edits.
  - Watch sync snapshots derive membership from in-memory conversations and flag `bodyUnavailableIDs` for metadata-only entries so empty placeholders are never published as bodies.
  - Spotlight indexing skips metadata-only placeholders on normal startup to avoid clobbering rich index entries (republishing placeholders only after privacy cleanup clears the domain), and domain deletion is serialized on `spotlightOperationQueue` behind prior index submissions.

## Consequences

### Positive
- Dev builds and test suites never trigger macOS Keychain prompts or touch production user data.
- Credentials and user conversation text cannot leak via plaintext diagnostics files or provider error echoes.
- Metadata-first startup stays fast without risking silent data loss during concurrent edits, deletes, or reloads.

### Negative
- Requires maintaining baseline tracking and serialization queues across persistence and Spotlight paths.

### Neutral
- Builds directly on [ADR-0002](0002-encrypted-conversation-storage.md) and [ADR-0007](0007-revisioned-watch-sync.md).

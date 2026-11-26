# ADR-0012: User Memory and Conversation Summary Architecture

**Date**: 2026-11-26  
**Status**: Accepted  
**Context**: Long-term user memory and cross-conversation summaries must balance privacy, persistence safety, and model context-window budgets.

## Context

Ayna extracts durable user facts (`UserMemoryService`, `MemoryFactExtractor`) and conversation summaries (`ConversationSummaryService`) and injects them into prompts (`MemoryContextProvider`). Naive background extraction and persistence can leak conversation data to unexpected providers, overwrite encrypted stores if a save fires before initial load finishes, or resurrect memories after a user clears them.

## Decision

### 1. Privacy-First Extraction & Local Summary Generation
- Fact extraction (`MemoryFactExtractor`) prefers on-device Apple Intelligence when available so conversation content never leaves the device. When on-device extraction is unavailable, it falls back to the conversation's own model (which already saw those messages), never silently sending content to an unrelated third-party provider.
- Conversation summaries (`ConversationSummaryService.generateSummary(for:)`) are built synchronously and entirely locally from user-message prefixes and keyword frequencies, without invoking Apple Intelligence or any remote model.

### 2. Non-Destructive Load/Save Reconciliation
- Edits arriving before initial encrypted load completes are queued (`PendingChange` / `initialLoadTask`) and replayed once loaded.
- Read failures never mark an empty digest as loaded, preventing premature saves from wiping existing encrypted memory or summary stores.

### 3. Clear-Generation Fencing & Confirmation Boundary
- Clearing memory increments `memoryClearGeneration` (and tracks `activeMemoryClears`) so in-flight backfills or background extractions cannot resurrect cleared facts or summaries.
- Chat commands cannot directly wipe all user memory; full erasure requires explicit UI confirmation.

### 4. Context-Window-Aware Budgeting
- `MemoryContextProvider` adapts injected memory/summary budgets to the active model's context window: summaries are dropped for `< 8K` models, scaled down for `8K–32K` models, and included at full budget above `32K`.

## Consequences

### Positive
- Protects user privacy by defaulting to on-device extraction and respecting provider boundaries.
- Eliminates race conditions between startup loads, background extractions, and user-initiated clears.

### Negative
- Adds generation-fencing state and pending-edit queues to memory services.

### Neutral
- Memory storage uses the same encrypted persistence conventions as [ADR-0002](0002-encrypted-conversation-storage.md).

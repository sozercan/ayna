# ADR-0009: Request Ownership, Streaming Pipeline, and Tool-Chain Coordination

**Date**: 2026-11-26  
**Status**: Accepted  
**Context**: Concurrent AI requests, retries, cancellations, multi-model generations, and tool-call loops require strict ownership fencing and deterministic callback ordering across background transport tasks and `@MainActor` UI state.

## Context

Ayna streams responses from multiple AI providers (OpenAI Chat Completions, OpenAI Responses API, Azure OpenAI, Anthropic, Apple Intelligence) while supporting user cancellation, automatic retries, image generation/editing, multi-model parallel responses, and multi-round tool execution. Without explicit ownership fencing and byte-oriented streaming, stale network completions can corrupt newer requests, quiet streams can lose trailing tokens on cancel, and out-of-order tool callbacks can double-launch continuations.

## Decision

### 1. Request Flight & Operation Ownership Fencing
- Every logical text, multi-model, and image request is assigned an owner-specific `RequestFlight` / `OperationID` (`AIService`, `OpenAIImageService`, `AnthropicProvider`, `ImageGenerationCoordinator`).
- Ownership is installed **before** dispatching to the provider because providers may fail synchronously.
- Starting a new logical operation atomically cancels and fences its predecessor; stale completions, retries, or async attachment loads check ownership before mutating state and cannot clear or deliver into a replacement request.
- ViewModels (`IOSChatViewModel.cancelOwnedOperations()`) cancel only operations owned by the departing instance so view disappearance cannot cancel a replacement ViewModel's work for the same conversation.
- Accepted send payloads (`PreparedSend`) are captured independently of the live composer so retrying a failed request never overwrites or merges with a new draft typed while the request was running.

### 2. Byte-Oriented SSE Streaming & Delivery Semantics
- Byte streams are read and parsed off the main actor (`AIService`, `OpenAIStreamParser`, `AnthropicStreamParser`), passing UTF-8 `Data` slices directly to `JSONSerialization` to avoid `Data -> String -> Data` round trips.
- Ownership checks and chunk delivery hop back to `@MainActor` per parsed SSE event rather than buffering a trailing chunk across reads; deferring a short tail until a later event can silently lose tokens if the user stops a quiet stream between events. Platform views own their own render throttling.
- Residual SSE `data:` records without a trailing newline are parsed once before EOF finalization because some providers close the connection immediately after the final event.
- Anthropic streaming requests default to a larger `max_tokens` ceiling (64,000) because streaming has no HTTP timeout pressure, while non-streaming requests stay smaller to finish within the request timeout. Anthropic `x-api-key` and `anthropic-version` headers are sent for both direct and Azure Foundry endpoints, while beta headers are withheld on Azure Foundry.

### 3. Deterministic Tool-Chain & Multi-Tool Round Coordination
- `ToolChainCoordinator` enqueues synchronous provider callback bookkeeping in a nonisolated lock-backed FIFO queue drained by a single `@MainActor` drain loop, checking operation ownership before every mutation and allowing already-queued terminal callbacks to complete cleanly on cancel.
- `ToolCallRequestRoundCoordinator` enforces per-round tool-call bounds off the main actor before callbacks enter the main-actor queue, retains callback registration order while allowing concurrent out-of-order tool completion, and guarantees exactly-once continuation launch via an ownership probe.

### 4. Cancellation Bookkeeping & Multi-Model Placeholders
- `ChatGenerationFinalizer` preserves partial assistant output on cancellation rather than discarding it.
- Empty single-response text placeholders are pruned on cancel, whereas empty multi-model placeholders are retained so their failed terminal state remains visible inside the response group.

## Consequences

### Positive
- Eliminates race conditions between overlapping retries, cancellations, and replacement sends.
- Preserves partial output and prevents silent token loss on quiet streams.
- Keeps main-actor work bounded during high-throughput SSE streaming.

### Negative
- Requires threading flight/operation IDs through transport, parser, and ViewModel layers.

### Neutral
- Render throttling remains the responsibility of platform views (`MacChatView`, `IOSChatView`, `WatchChatViewModel`).

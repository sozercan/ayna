# ADR-0007: Revisioned Durable Watch Sync

**Date**: 2026-07-12
**Status**: Accepted
**Context**: Apple Watch conversations must remain correct across offline edits, bounded WatchConnectivity payloads, retries, deletions, app restarts, and mixed app versions.

## Context

The original Watch sync treated the phone application context as a bounded list of conversation bodies and sent Watch edits as independent best-effort messages. That model could not distinguish a body omitted for size from a deletion, could not represent an authoritative empty state, and allowed delayed snapshots or component deliveries to overwrite newer local work. Streaming and tool-call state also existed only in memory until completion, so termination could lose prompts or partial responses.

WatchConnectivity offers transports with different delivery guarantees and strict practical payload limits. Both devices may be offline, callbacks may arrive out of order, and a transfer finishing does not prove that the receiver durably applied it. Model credentials, prompts, and memory add another omission problem: a value absent from a bounded page may mean “not represented yet” rather than “clear it.” The protocol therefore needs explicit identity, ordering, durability, authority, and compatibility rules rather than timestamp or array-position heuristics.

## Decision

Use a revisioned, phone-authoritative snapshot plus a durable Watch mutation outbox.

- Every phone snapshot carries a stable source ID and monotonically increasing snapshot revision. Rotating the source ID resets revision ordering after overflow or source replacement.
- A snapshot carries an explicit authoritative conversation-ID manifest. Conversation bodies are independently bounded; omission of a body is never interpreted as deletion.
- Deletions are represented by revisioned tombstones, including authoritative empty state.
- Each Watch installation has a durable peer ID. Watch-originated mutations carry per-conversation revisions and stable operation/message IDs.
- The Watch persists committed conversations, pending mutations, and request-owned drafts before transport. Failed local persistence rolls the visible mutation back and leaves no false acknowledgement.
- The phone reduces mutations by peer and revision while preserving phone-only fields. It acknowledges a mutation only after the resulting save/delete state is durably settled, including ID-only deletes for records omitted from memory. Competing proposed-save chains retain their pre-proposal durable state and compensate storage before a failed replacement receipt settles.
- Phone snapshots are constructed from the durable storage snapshot rather than optimistic UI state. Successful later persistence advances a durable revision that retriggers Watch publication; superseded or failed reloads cannot replace that publication snapshot.
- A phone conversation load is authoritative only when every encrypted record is readable. Partial or later failed reloads revoke authority before retry scheduling, so stale state cannot publish false deletions or acknowledgements.
- Application-context payload construction is deterministic and byte-bounded. Conversation bodies, acknowledgements, tombstones, models, prompts, and memory data have explicit fallback priorities. An irreducible configuration is deferred without truncation while the page cursor advances; that cycle remains non-authoritative and a later cycle re-evaluates the record.
- Snapshot-coupled settings apply only with a durably accepted snapshot page or a valid legacy fallback context. A standalone page-cycle retry retains the exact source/request identity of the in-flight cycle.
- Model metadata is accumulated across a page cycle. A new metadata epoch remains provisional until a complete authoritative replacement arrives; only then is the epoch committed and stale metadata pruned.
- Model-removal history is bounded and rotates with its epoch. Persistent SHA-256 field fingerprints revoke omitted providers, endpoints, OAuth flags, and API keys even when a bounded metadata cycle remains provisional. Selectable models come only from configured model metadata; conversation-referenced models remain transport-only fallbacks. Every advertised selectable model is included in the same publication's metadata coverage, even in reduced contexts.
- Prompts are never truncated. Values larger than the old character cap are admitted when they fit the actual byte budget. If a prompt cannot fit, the page carries an explicit unavailable/empty gate that clears stale Watch instructions, remains non-authoritative, and is retried until a later lossless value fits. Watch-created conversations retain global-prompt inheritance; omission preserves an existing default prompt while an explicit empty value clears it.
- Memory facts are published only when the phone has authoritative facts and the encrypted write or clear has succeeded. Writes are serialized by generation, and local edits racing the initial encrypted load are journaled and merged before persistence. Reduced/non-authoritative contexts omit memory rather than imply deletion; an authoritative empty list explicitly clears it. Enabling memory again retries a failed or not-yet-complete load without replacing optimistic facts from stale disk.
- Oversized Watch mutations use file transfer rather than truncating message deltas. Ingress validates the active session and metadata before touching the file, enforces a shared 4 MiB ingress/egress bound, performs bounded reads, and verifies payload identity. A local enqueue or size failure schedules the same durable retry path, so the outbox cannot become stranded.
- Interactive messages reduce latency, while user-info/file transfers and retry backoff provide durable delivery. Snapshot acknowledgements clear only matching-peer durable outbox entries.
- During capability discovery, the Watch may dual-send legacy components and revisioned mutations. Once a supported revisioned snapshot is observed, the peer adopts revisioned mode; unsupported schemas do not change mode. Legacy operations awaiting phone authority use a separate retained FIFO so they cannot block later WCSession lifecycle or revisioned events. Legacy transfer markers and cumulative echo coverage survive ordinary activation together, while acknowledgement still requires fresh evidence from the current context; a known revisioned source transition resets both evidence classes.
- Request-owned streaming/tool drafts are overlaid on phone snapshots by stable message identity. Cancellation, restart recovery, and title generation are fenced by request/conversation ownership. Tool-call duplicate IDs are scoped to one provider request round; ID-less calls receive deterministic round-local IDs so later rounds cannot suppress valid work.
- Model selection persists the conversation change before updating global selection or dismissing the UI.
- Persisted Watch conversation bodies use a 20-body recency soft limit. Bodies owned by pending mutations, request drafts, the current/selected conversation, or retained legacy delivery coverage are protected from eviction; manifest omission still never means deletion.
- A native `Ayna-watchOSTests` target and shared-scheme test action run the Watch-only Swift Testing suites in CI, alongside the existing Watch UI smoke tests.
- Watch mutation revisions never wrap. At revision exhaustion, transport mutation creation fails and the user's message/title/configuration/deletion intent remains durably deferred locally rather than being acknowledged as stale revision `1`.

The same reliability increment hardens Watch-available web fetching. Redirect targets and connected remote endpoints are validated against private/local address policy. One absolute request deadline covers initial DNS, redirect DNS, and URLSession transfer; a stalled non-cancelable system resolver cannot hold the caller past that deadline. Proxied transactions are rejected because URLSession task metrics expose the proxy connection rather than a verifiable origin endpoint. Preflight DNS resolution plus post-connection validation reduces DNS-rebinding exposure, but does not pin the exact preflight address before the GET. Eliminating that remaining race requires a custom address-pinned HTTP/TLS transport and is intentionally outside this decision. `TavilyService` retains URLSession in production but exposes an injected async data loader so watchOS-native tests never depend on unsupported custom `URLProtocol` interception.

## Consequences

### Positive

- Empty state, deletion, bounded omission, provisional metadata, and explicit clears have distinct meanings.
- Offline Watch prompts, edits, tool results, and partial responses survive restart and retry without silent truncation; unavailable prompt gates prevent stale instructions from being used.
- Delayed snapshots, duplicate callbacks, stale acknowledgements, and stale metadata epochs are idempotent and cannot overwrite newer state.
- Phone-only conversation metadata remains authoritative while Watch-owned message deltas can merge safely.
- Credentials, endpoints, prompts, and memory cannot be cleared merely because a bounded page omitted them, cannot be advertised without matching metadata, and cannot be published before their required persistence succeeds.
- Payload and file-transfer behavior is deterministic and testable under strict byte/resource budgets.
- Native Watch-only reliability tests execute automatically in CI instead of silently compiling out on macOS.
- Mixed-version phone/watch pairs retain a bounded legacy compatibility path.
- Web-fetch redirects and connected endpoints fail closed when they cannot be tied to an allowed public origin.

### Negative

- Sync state now includes source/peer identities, revisions, tombstones, acknowledgements, metadata epochs, invalidation fingerprints, prompt availability, draft overlays, body-recency metadata, and retry bookkeeping.
- Both devices persist protocol metadata in addition to conversations, and Watch selection changes may write recency state even when conversation content is unchanged.
- A mutation may remain pending after the phone already applied it if the acknowledgement cannot be persisted locally; retries must remain idempotent.
- One unreadable encrypted conversation keeps phone state non-authoritative until the record is repaired or removed.
- Revision-exhausted Watch intent remains visible and durable but cannot synchronize automatically until a future explicit epoch-rotation design is introduced.
- Legacy compatibility temporarily duplicates transport work until peer capability is known; marker-less legacy model metadata is treated as a complete replacement, while explicit bounded metadata remains provisional.
- Proxied web fetching is unavailable because the origin connection cannot be validated with the current URLSession metrics boundary.

### Neutral

- The phone remains authoritative for the complete conversation and configuration model; the Watch owns only explicit local mutations and request drafts.
- Conversation bodies remain intentionally bounded on Watch. Full phone history is not guaranteed to be mirrored, and protected pending/draft bodies may temporarily exceed the ordinary 20-body soft limit.
- Timestamps continue to drive display ordering, but never determine conflict resolution.
- Completely closing the residual DNS preflight-to-connect race is deferred until a custom pinned transport is justified.

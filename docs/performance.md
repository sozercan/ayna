# Performance Checklist

Before completing non-trivial features, verify these patterns are followed.

## Streaming & Network

- [ ] **Streaming responses handled incrementally** — Never buffer entire response before displaying
- [ ] **Network requests are cancellable** — Use `Task` with proper cancellation, not fire-and-forget
- [ ] **Retry logic uses exponential backoff** — See `AIRetryPolicy` for the pattern
- [ ] **Large payloads are chunked** — Don't send/receive massive JSON in one request

## UI Performance

- [ ] **Conversation lists use `LazyVStack`** — Not `VStack` for potentially long lists
- [ ] **Message views avoid re-renders** — Extract expensive markdown rendering to subviews
- [ ] **No `await` calls inside `ForEach`** — Fetch data before iteration
- [ ] **Images/attachments use async loading** — Never block UI thread for file I/O
- [ ] **Search input is debounced** — Not firing on every keystroke
- [ ] **Frequently updating UI caches formatted strings** — Don't recompute on every render

## Memory Management

- [ ] **Streaming chunks are processed, not accumulated** — `StreamingChunkBuffer` clears after processing
- [ ] **Attachments cleaned up on conversation delete** — `AttachmentStorage` handles orphan cleanup
- [ ] **Long conversations paginate** — Don't load 1000+ messages into memory at once
- [ ] **Observation is scoped** — Use `@Observable` on small units, not entire app state

## Persistence

- [ ] **Saves are debounced** — Don't save on every keystroke; use `ConversationPersistenceCoordinator`
- [ ] **Encryption happens off main thread** — Use `Task { }` for crypto operations
- [ ] **Metadata loads fast** — Conversation list shouldn't decrypt all content upfront

## MCP & Subprocess (macOS only)

- [ ] **MCP processes are tracked** — `MCPProcessTracker` monitors lifecycle
- [ ] **Subprocess timeouts enforced** — Don't let hung tools block indefinitely
- [ ] **Resources cleaned up on termination** — Processes killed on app quit

## Cross-Platform

- [ ] **Core code avoids platform-specific overhead** — No UIKit/AppKit in Core without guards
- [ ] **watchOS is memory-conscious** — Smaller buffers, fewer cached items
- [ ] **iOS handles backgrounding** — Save state before suspension

## Concurrency Safety

- [ ] **No fire-and-forget `Task { }` without error handling** — Track tasks, handle errors
- [ ] **Optimistic updates handle `CancellationError` explicitly** — Rollback on cancel, not just on error
- [ ] **Background tasks cancelled in `deinit`** — Prevent work after deallocation
- [ ] **Using `.task` instead of `.onAppear { Task { } }`** — Lifecycle-managed, auto-cancelled
- [ ] **ForEach uses stable identity** — Use model ID, not array index
- [ ] **Non-Sendable types stay on their actor** — `NSImage`/`UIImage` don't cross actor boundaries
- [ ] **@MainActor singletons accessed correctly** — Use `await` or `@MainActor` caller

## Verification Commands

```bash
# Profile memory usage (Instruments)
xcrun xctrace record --template 'Allocations' --launch -- /path/to/Ayna.app

# Check for main thread violations
xcrun xctrace record --template 'Main Thread Checker' --launch -- /path/to/Ayna.app
```

# ADR-0013: Platform UI, Multimodal Input, and Interaction Decisions

**Date**: 2026-11-26  
**Status**: Accepted  
**Context**: Non-obvious macOS, iOS, watchOS, multimodal, web-search, and UI-testing behaviors depend on OS framework constraints and deliberate UX trade-offs.

## Context

Several platform interactions (AppKit panel focus, macOS termination hooks, SwiftUI scroll tracking, Watch persistence costs, multimodal image limits, web search formatting, and XCUITest accessibility behavior) have counterintuitive constraints where the obvious implementation fails or degrades UX.

## Decision

### 1. macOS App Lifecycle & "Work with Apps"
- Async persistence flushes (memory, summaries, conversations) run in `applicationShouldTerminate` using `.terminateLater` with a timeout, never in `applicationWillTerminate` where newly spawned Swift `Task`s do not execute before process exit (`aynaApp`).
- "Work with Apps" hotkey and panel handlers are always wired at launch regardless of toggle state or registration outcome so enabling the feature or recording a new hotkey works without relaunching.
- The global hotkey opens a Spotlight-style floating `NSPanel` without auto-capturing focused app content; context attachment is opt-in for privacy.
- `FloatingPanelController` configures `NSPanel` with `[.titled, .fullSizeContentView, .nonactivatingPanel]`, a hidden transparent titlebar, and `becomesKeyOnlyIfNeeded = false` (via `KeyablePanel`) because borderless `NSPanel`s cannot become key windows for text input.
- Global hotkeys persist as layout-independent numeric `<modifiers>:<keyCode>` while rendering printable key labels from the active keyboard layout, rejecting Shift-only and reserved macOS shortcuts (`HotkeyCombination`), and capturing `frontmostApplication` immediately before Ayna activates (`GlobalHotkeyService`).
- Content truncation is type-aware (`AppContent`): terminal output keeps the **end** (most recent lines), while documents and selections keep the **start**.

### 2. Multimodal Image Limits & Edit Chain Semantics
- Composer attachment count (20 images per request, `ChatDraftContent`) and clipboard paste size (3.75 MiB, `PastedImage`) enforce the strictest supported provider limits (Anthropic) so drafts remain portable across providers.
- Image edits (`ConversationSendPreflight`, `ImageEditContext`) follow an asymmetric fail-closed policy:
  - Explicit images attached to the triggering user message take precedence over prior generated images, and an unreadable user attachment aborts the send rather than silently editing a different image.
  - Without explicit attachments, the most recent generated (or selected multi-model) image continues the edit chain; if that prior image is missing, it falls back to fresh generation.
  - Prior generated images sniff MIME type from raw bytes because the GPT Image output format setting (JPEG/WebP/PNG) may have changed between turns.
  - GPT Image models reject `response_format` and return base64 by default; DALL·E returns URLs that `OpenAIImageService` downloads immediately.

### 3. Streaming Rendering & Observation Performance
- `ConversationManager.modifyConversation` batches mutations into a single in-place write to `@Published var conversations` so SwiftUI observes one invalidation per flush.
- `MacChatView` uses **throttling** (not debouncing) for stream chunk UI flushes so high-frequency tokens cannot starve rendering.
- `MacNewChatView` defers switching `selectedConversationId` to `MacChatView` until the first generation finishes so the active view and its stop button remain intact during initial streaming.
- `SyntaxHighlightedCodeView` skips regex highlighting above 32 KB and renders plain selectable monospaced text to prevent main-thread stalls.
- Regular chat messages parse markdown synchronously on init to avoid empty-bubble flashes, while collapsed `.tool` messages (and large macOS messages) defer parsing off the main thread.
- Attachment image decoding runs off-actor via ImageIO, while non-`Sendable` `NSImage` construction stays `@MainActor`-confined and cached per message.
- On watchOS, 100 ms streaming ticks stay in memory (`persist: false`) because re-encoding `WatchConversationStore` to `UserDefaults` on every tick was the primary streaming bottleneck; persistence occurs when the draft finishes.
- `StreamingFollowScroll` tracks scroll geometry rather than lazy row `onAppear`/`onDisappear`, disengages only on user scroll phases (`.interacting`/`.decelerating`), and hands off reading position across the new-chat → chat transition as a vertical content offset so position is preserved inside a single long streaming reply.

### 4. Web Search & Citations
- Model-facing web search context (`WebSearchModels`) includes a synthesis preamble and intentionally omits URLs and citation numbers because sources are rendered separately via `CitationReference` in the UI.
- `DuckDuckGoSearchService` uses form-encoded `POST` rather than `GET` against DuckDuckGo's HTML endpoint to avoid CAPTCHA challenges.

### 5. Watch Complication & UI Testing Conventions
- `WatchComplication/AynaComplication.swift` is intentionally a static launcher widget that reads no app data and needs no App Group.
- macOS UI tests assert row deletion against `XCUIElementQuery.count == 0` rather than a resolved element's `exists == false`, because SwiftUI `List` can recycle accessibility objects for removed rows.
- On iOS 26+, SwiftUI `TextField` with `axis: .vertical` may be exposed as `textView` rather than `textField` in XCUITest.

## Consequences

### Positive
- Preserves hard-won Apple framework and UX invariants in durable documentation instead of scattered inline comments.

### Negative
- Must be kept updated when platform SDK behaviors change (e.g., future SwiftUI or AppKit releases).

### Neutral
- Complements [ADR-0003](0003-cross-platform-core.md), [ADR-0005](0005-anthropic-provider.md), and [ADR-0007](0007-revisioned-watch-sync.md).

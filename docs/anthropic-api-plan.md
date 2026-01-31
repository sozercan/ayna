# Plan: Add Anthropic API Support

## Overview

Add Anthropic (Claude) API support to Ayna, following the existing provider architecture pattern. The implementation will support:
- Direct Anthropic API and custom endpoints (Azure, etc.)
- Configurable API keys per model
- Tool use for MCP integration
- Extended thinking with streaming thinking blocks (including interleaved thinking)
- Vision/image attachments in messages
- Manual model entry (no preset list)

> **Note:** Prompt caching is deferred to post-MVP. Focus on core functionality first.

## Files to Create

| File | Purpose |
|------|---------|
| `Core/Services/Providers/AnthropicProvider.swift` | Main provider implementation |
| `Core/Services/AnthropicRequestBuilder.swift` | Request body construction |
| `Core/Services/AnthropicStreamParser.swift` | SSE parsing for Anthropic format |
| `Core/Services/AnthropicEndpointResolver.swift` | URL resolution for endpoints |
| `Tests/aynaTests/AnthropicProviderTests.swift` | Provider unit tests |
| `Tests/aynaTests/AnthropicStreamParserTests.swift` | Stream parser tests |
| `Tests/aynaTests/AnthropicRequestBuilderTests.swift` | Request builder tests |
| `Tests/aynaTests/AnthropicEndpointResolverTests.swift` | Endpoint resolver tests |

## Files to Modify

| File | Changes |
|------|---------|
| `Core/Services/AIService.swift` | Add `.anthropic` case to `AIProvider` enum |
| `Core/Services/Providers/AIProviderProtocol.swift` | Update `AIProviderFactory` |
| `Core/Diagnostics/DiagnosticsLogger.swift` | Add `.anthropicService` category |

## Implementation Phases

---

### Phase 1: Core Infrastructure

**Deliverables:**
1. Add `anthropic` case to `AIProvider` enum in `AIService.swift`
2. Update `AIProviderFactory.createProvider()` to handle `.anthropic` (stub returning `fatalError("Not implemented")`)
3. Add `.anthropicService` diagnostic category in `DiagnosticsLogger.swift`

**Exit Criteria:**
| Check | Command |
|-------|---------|
| macOS builds | `xcodebuild -scheme Ayna -destination 'platform=macOS' build` ✅ |
| iOS builds | `xcodebuild -scheme Ayna-iOS -destination 'platform=iOS Simulator,name=iPhone 17' build` ✅ |
| watchOS builds | `xcodebuild -scheme Ayna-watchOS -destination 'platform=watchOS Simulator,name=Apple Watch Ultra 3 (49mm)' build` ✅ |
| All `switch` on `AIProvider` exhaustive | No compiler warnings about unhandled cases |
| Existing tests pass | `xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaTests` ✅ |

**Rollback:** Revert 3 file changes; codebase remains functional.

---

### Phase 2: Endpoint Resolver

**Deliverables:**
1. Create `Core/Services/AnthropicEndpointResolver.swift`
2. Default endpoint: `https://api.anthropic.com/v1/messages`
3. Custom endpoint support with HTTPS validation
4. Create `Tests/aynaTests/AnthropicEndpointResolverTests.swift`

**Implementation:**
- `messagesURL(customEndpoint: String?) -> URL` method
- Validate HTTPS scheme; throw `AynaError` for HTTP or malformed URLs
- Strip trailing slashes, append `/v1/messages` if base URL provided

**Exit Criteria:**
| Check | Verification |
|-------|--------------|
| Default URL correct | Test: `resolver.messagesURL(customEndpoint: nil)` returns `https://api.anthropic.com/v1/messages` |
| Custom URL works | Test: `resolver.messagesURL(customEndpoint: "https://my-proxy.com")` returns `https://my-proxy.com/v1/messages` |
| HTTP rejected | Test: `resolver.messagesURL(customEndpoint: "http://insecure.com")` throws error |
| Malformed URL rejected | Test: `resolver.messagesURL(customEndpoint: "not-a-url")` throws error |
| All platforms build | All 3 platform builds pass |
| Tests pass | `xcodebuild test -only-testing:aynaTests/AnthropicEndpointResolverTests` ✅ |

**Rollback:** Delete new files; Phase 1 remains functional.

---

### Phase 3: Request Builder

**Deliverables:**
1. Create `Core/Services/AnthropicRequestBuilder.swift`
2. Create `Tests/aynaTests/AnthropicRequestBuilderTests.swift`

**Implementation:**
- Extract system prompt from messages array → top-level `system` parameter
- Convert messages to Anthropic format (role mapping, content blocks)
- Convert OpenAI tool format → Anthropic `input_schema` format
- Convert image attachments → Anthropic image content blocks
- Validate image media types via magic bytes (JPEG: `FF D8 FF`, PNG: `89 50 4E 47`, GIF: `47 49 46 38`, WebP: `52 49 46 46...57 45 42 50`)
- Enforce limits: max 20 images, max 3.75 MB per image
- Set required headers: `x-api-key`, `anthropic-version: 2023-06-01`, `Content-Type: application/json`
- Support `anthropic-beta` header (comma-separated)
- Default `max_tokens` to 4096 when not configured

**Exit Criteria:**
| Check | Verification |
|-------|--------------|
| System prompt extraction | Test: Messages `[{role: system, content: "X"}, {role: user, content: "Y"}]` → `{system: "X", messages: [{role: user, content: "Y"}]}` |
| Role mapping | Test: `assistant` stays `assistant`, `user` stays `user` |
| Tool conversion | Test: OpenAI `{type: function, function: {name, description, parameters}}` → `{name, description, input_schema}` |
| Image block format | Test: Attachment → `{type: image, source: {type: base64, media_type, data}}` |
| Image validation (JPEG) | Test: Data starting with `FF D8 FF` → `image/jpeg` |
| Image validation (PNG) | Test: Data starting with `89 50 4E 47` → `image/png` |
| Image count limit | Test: 21 images throws error |
| Image size limit | Test: 4 MB image throws error |
| `max_tokens` default | Test: No config → `max_tokens: 4096` in request body |
| Required headers present | Test: Request has `x-api-key`, `anthropic-version`, `Content-Type` |
| Beta headers | Test: `["beta1", "beta2"]` → `anthropic-beta: beta1,beta2` |
| All platforms build | All 3 platform builds pass |
| Tests pass | `xcodebuild test -only-testing:aynaTests/AnthropicRequestBuilderTests` ✅ |

**Rollback:** Delete new files; Phase 2 remains functional.

---

### Phase 4: Stream Parser

**Deliverables:**
1. Create `Core/Services/AnthropicStreamParser.swift`
2. Create `Tests/aynaTests/AnthropicStreamParserTests.swift` with fixtures

**Implementation:**

**SSE Line Format (differs from OpenAI):**
```
event: message_start
data: {"type": "message_start", ...}

event: content_block_delta
data: {"type": "content_block_delta", ...}
```

Two-line buffering:
```swift
var pendingEventType: String?

for line in stream {
    if line.hasPrefix("event: ") {
        pendingEventType = String(line.dropFirst(7))
    } else if line.hasPrefix("data: ") {
        let data = String(line.dropFirst(6))
        if !data.trimmingCharacters(in: .whitespaces).isEmpty {
            processEvent(type: pendingEventType, data: data)
        }
        pendingEventType = nil
    }
}
```

**Event Handling:**
| Event | Delta Type | Action |
|-------|------------|--------|
| `message_start` | - | Initialize state, extract message metadata |
| `content_block_start` | - | Track block type and index (`text`, `thinking`, `tool_use`) |
| `content_block_delta` | `text_delta` | Call `onChunk` callback |
| `content_block_delta` | `thinking_delta` | Call `onReasoning` callback |
| `content_block_delta` | `input_json_delta` | Accumulate tool input JSON |
| `content_block_delta` | `signature_delta` | Accumulate thinking signature |
| `content_block_stop` | - | If tool_use: parse accumulated JSON, call `onToolCallRequested` |
| `message_delta` | - | Extract `stop_reason` (`end_turn`, `tool_use`, `stop_sequence`, `max_tokens`) |
| `message_stop` | - | Call `onComplete` |
| `ping` | - | Ignore (keep-alive) |
| `error` | - | Call `onError` |

**Multi-block state tracking (for interleaved thinking):**
```swift
struct BlockState {
    let type: ContentBlockType  // text, thinking, redacted_thinking, tool_use
    var buffer: Data            // Use Data for correct UTF-8 handling
    var toolName: String?
    var toolId: String?
}

var activeBlocks: [Int: BlockState] = [:]
```

**Edge cases:**
- `redacted_thinking` blocks: signature only, don't call `onReasoning` with empty content
- Tool JSON parse failure: log buffer, emit synthetic error result, don't crash
- Empty `data:` lines: skip without error (keep-alive)

**Exit Criteria:**
| Check | Verification |
|-------|--------------|
| `message_start` parsing | Test: Fixture → state initialized |
| `content_block_start` (text) | Test: Fixture → block tracked with type `text` |
| `content_block_start` (thinking) | Test: Fixture → block tracked with type `thinking` |
| `content_block_start` (tool_use) | Test: Fixture → block tracked with id and name |
| `text_delta` handling | Test: Fixture → `onChunk` called with text |
| `thinking_delta` handling | Test: Fixture → `onReasoning` called with thinking |
| `input_json_delta` accumulation | Test: 3 fragments → complete JSON after `block_stop` |
| `content_block_stop` (tool_use) | Test: Accumulated JSON parsed, `onToolCallRequested` called |
| `message_delta` stop_reason | Test: Fixture with `stop_reason: end_turn` → extracted |
| `message_stop` | Test: Fixture → `onComplete` called |
| `ping` ignored | Test: Ping event → no callbacks |
| `error` handling | Test: Error event → `onError` called |
| Two-line format | Test: `event:` + `data:` pairs correlated correctly |
| Empty data line | Test: `data: ` (empty) → skipped without error |
| Interleaved thinking | Test: Fixture with thinking at index 0, text at index 1, more thinking at index 0 → both tracked correctly |
| Malformed tool JSON | Test: Invalid JSON → logged, synthetic error, stream continues |
| `redacted_thinking` | Test: Block with signature only → no empty `onReasoning` call |
| All platforms build | All 3 platform builds pass |
| Tests pass | `xcodebuild test -only-testing:aynaTests/AnthropicStreamParserTests` ✅ |

**Rollback:** Delete new files; Phase 3 remains functional.

---

### Phase 5: Provider Implementation

**Deliverables:**
1. Create `Core/Services/Providers/AnthropicProvider.swift`
2. Create `Tests/aynaTests/AnthropicProviderTests.swift`
3. Update `AIProviderFactory` to return `AnthropicProvider` for `.anthropic`

**Implementation:**
```swift
@MainActor final class AnthropicProvider: AIProviderProtocol {
    private var currentStreamTask: Task<Void, Error>?
    private let circuitBreaker: NetworkCircuitBreaker
    // ...
}
```

**Requirements:**
- `@MainActor final class` per AGENTS.md
- Use `AnthropicEndpointResolver` for URL resolution
- Use `AnthropicRequestBuilder` for request construction
- Use `AnthropicStreamParser` for response parsing
- Circuit breaker with key `"anthropic"`
- Retry logic via `AIRetryPolicy`
- `#if os(macOS)` guards for MCP tool-related code
- Track `currentStreamTask` with `defer { currentStreamTask = nil }`
- Check `Task.isCancelled` in stream loop; don't call `onError` for cancellation
- Parse Anthropic error format: `{"type": "error", "error": {"type": "...", "message": "..."}}`
- Include "Anthropic" in error messages (e.g., "Anthropic API key invalid")

**Exit Criteria:**
| Check | Verification |
|-------|--------------|
| Conforms to `AIProviderProtocol` | Compiles with protocol conformance |
| `@MainActor final class` | Code review: annotation present |
| Factory returns provider | Test: `AIProviderFactory.createProvider(.anthropic)` returns `AnthropicProvider` |
| Streaming mock test | Test: Mock response → `onChunk` callbacks received |
| Non-streaming mock test | Test: Mock response → complete message returned |
| Cancellation (content) | Test: Cancel during stream → no `onError`, task cancelled |
| Cancellation (thinking) | Test: Cancel during thinking → clean cancellation |
| HTTP 400 error | Test: Mock 400 → appropriate error with "Anthropic" prefix |
| HTTP 401 error | Test: Mock 401 → "Anthropic API key invalid" message |
| HTTP 429 error | Test: Mock 429 → retry behavior triggered |
| HTTP 500 error | Test: Mock 500 → retry with backoff |
| Anthropic error format | Test: `{"type": "error", ...}` → parsed correctly |
| Circuit breaker integration | Test: Multiple failures → circuit opens |
| MCP tools macOS-only | Code review: `#if os(macOS)` guards present |
| `currentStreamTask` cleanup | Code review: `defer` pattern present |
| All platforms build | All 3 platform builds pass |
| Tests pass | `xcodebuild test -only-testing:aynaTests/AnthropicProviderTests` ✅ |

**Rollback:** Revert factory change, delete new files; Phase 4 remains functional.

---

### Phase 6: Integration & Quality Assurance

**Deliverables:**
1. Full test suite passes
2. Linting passes
3. All platform builds pass
4. Code review checklist complete

**Exit Criteria:**
| Check | Command/Verification |
|-------|---------------------|
| macOS build | `xcodebuild -scheme Ayna -destination 'platform=macOS' build` ✅ |
| iOS build | `xcodebuild -scheme Ayna-iOS -destination 'platform=iOS Simulator,name=iPhone 17' build` ✅ |
| watchOS build | `xcodebuild -scheme Ayna-watchOS -destination 'platform=watchOS Simulator,name=Apple Watch Ultra 3 (49mm)' build` ✅ |
| Unit tests | `xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaTests` ✅ |
| SwiftLint | `swiftlint --strict` reports 0 errors |
| SwiftFormat | `swiftformat .` makes no changes |
| No force unwraps | Code review: no `!` on API responses |
| No secrets logged | Code review: base64 data not in logs |
| DiagnosticsLogger used | Code review: `.anthropicService` category for all logs |

**Regression Checklist:**
- [ ] OpenAI provider still works
- [ ] GitHub Models provider still works
- [ ] Azure provider still works
- [ ] Apple Intelligence provider still works
- [ ] Existing conversations load correctly
- [ ] Tool execution works for existing providers

**Rollback:** N/A - this phase is verification only.

---

## Key API Differences (from SDK Analysis)

### Request Parameters
| Parameter | Type | Description |
|-----------|------|-------------|
| `model` | string | Required - model ID |
| `max_tokens` | number | Required - max tokens to generate |
| `messages` | array | Required - conversation messages |
| `system` | string/array | Top-level system prompt (not in messages). Array format for cache control. |
| `stream` | boolean | Enable streaming |
| `temperature` | number | 0.0-1.0 (default 1.0) |
| `stop_sequences` | array | Custom stop strings |
| `tools` | array | Tool definitions |
| `tool_choice` | object | Control tool usage (`auto`, `any`, `tool`, `none`) |
| `thinking` | object | Extended thinking config (`{type: "enabled", budget_tokens: N}`) |
| `metadata` | object | Request metadata |

### Request Headers
| Header | Value | Description |
|--------|-------|-------------|
| `x-api-key` | API key | Required - authentication |
| `anthropic-version` | `2023-06-01` | Required - API version |
| `anthropic-beta` | comma-separated | Optional - enable beta features |
| `Content-Type` | `application/json` | Required |

### Message Format
**OpenAI:**
```json
{"messages": [{"role": "system", "content": "..."}, {"role": "user", "content": "..."}]}
```

**Anthropic (simple):**
```json
{"system": "...", "messages": [{"role": "user", "content": "..."}]}
```

**Anthropic (with images - multi-part content):**
```json
{
  "system": "...",
  "messages": [{
    "role": "user",
    "content": [
      {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": "..."}},
      {"type": "text", "text": "What's in this image?"}
    ]
  }]
}
```

**Note:** Content can be a string OR an array of content blocks. Use array format when including images or for cache control.

### Stream Event Types
| Event | Data Type | Description |
|-------|-----------|-------------|
| `message_start` | Message metadata | Initialize message |
| `content_block_start` | ContentBlock | Start of text/thinking/tool_use block |
| `content_block_delta` | Delta | Incremental content |
| `content_block_stop` | index | Block complete |
| `message_delta` | Delta with stop_reason | Message ending |
| `message_stop` | - | Stream complete |
| `ping` | - | Keep-alive (ignore) |
| `error` | error object | Stream error |

### Content Block Types (Request)
| Type | Description | Usage |
|------|-------------|-------|
| `text` | Text content | `{"type": "text", "text": "..."}` |
| `image` | Image attachment | `{"type": "image", "source": {...}}` |
| `tool_result` | Tool execution result | `{"type": "tool_result", "tool_use_id": "...", "content": "..."}` |

### Content Block Types (Response)
| Type | Description | Streaming Delta |
|------|-------------|-----------------|
| `text` | Regular text content | `text_delta` |
| `thinking` | Extended thinking | `thinking_delta` |
| `redacted_thinking` | Redacted thinking (signature only) | `signature_delta` |
| `tool_use` | Tool call request | `input_json_delta` |

### Extended Thinking
Request:
```json
{"thinking": {"type": "enabled", "budget_tokens": 1024}}
```

Response block:
```json
{"type": "thinking", "thinking": "...", "signature": "..."}
```

Streaming: `thinking_delta` with `thinking` property

### Tool Use
**Tool Definition (Anthropic format):**
```json
{
  "name": "web_search",
  "description": "Search the web",
  "input_schema": {"type": "object", "properties": {...}, "required": [...]}
}
```

**Tool Use Block (response):**
```json
{"type": "tool_use", "id": "toolu_xxx", "name": "web_search", "input": {...}}
```

**Tool Result (send back):**
```json
{"type": "tool_result", "tool_use_id": "toolu_xxx", "content": "..."}
```

### Tool Definition Conversion (OpenAI -> Anthropic)
- `function.name` -> `name`
- `function.description` -> `description`
- `function.parameters` -> `input_schema`

## Data Flow

```
User Message
    |
    v
AIService.sendMessage()
    |
    +-> modelProviders[model] == .anthropic
    |
    v
AIProviderFactory.createProvider(.anthropic)
    |
    v
AnthropicProvider.sendMessage()
    |
    +-> AnthropicEndpointResolver.messagesURL()
    +-> AnthropicRequestBuilder.createMessagesRequest()
    +-> HTTP Request
    |
    v
SSE Stream -> AnthropicStreamParser
    |
    +-> onChunk (text content)
    +-> onReasoning (thinking blocks)
    +-> onToolCallRequested (tool use)
    +-> onComplete (message_stop)
```

## Verification

```bash
# Build all platforms
xcodebuild -scheme Ayna -destination 'platform=macOS' build
xcodebuild -scheme Ayna-iOS -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -scheme Ayna-watchOS -destination 'platform=watchOS Simulator,name=Apple Watch Ultra 3 (49mm)' build

# Run tests
xcodebuild -scheme Ayna -destination 'platform=macOS' test -only-testing:aynaTests

# Lint
swiftlint --strict && swiftformat .
```

## Manual Testing
1. Add a new model with provider "Anthropic" and API key
2. Set custom endpoint if needed (or leave empty for direct API)
3. Send a chat message and verify streaming response
4. Test tool use with MCP (macOS) or Tavily web search
5. Test extended thinking if model supports it (requires budget_tokens >= 1024)
6. Test vision by attaching an image and asking about it (verify base64 encoding and media_type)
7. Test interleaved thinking with Claude 4 models (verify multiple thinking blocks handled)
8. Verify `redacted_thinking` blocks are handled gracefully (no crash, no empty reasoning display)

## Additional Considerations from SDK

### Extended Thinking Requirements
- Minimum `budget_tokens`: 1024
- Counts towards `max_tokens` limit
- Returns `thinking` blocks before `text` blocks
- May return `redacted_thinking` blocks (signature only, no content)

### Error Handling
- HTTP 400: Invalid request (check model name, parameters)
- HTTP 401: Invalid API key
- HTTP 403: Permission denied / rate limit
- HTTP 429: Rate limited (check `retry-after` header)
- HTTP 500+: Server error (retry with backoff)

### Important Notes
- `max_tokens` is required (unlike OpenAI which has defaults)
- Default `anthropic-version: 2023-06-01` (stable version)
- Tool input is streamed as JSON fragments via `input_json_delta`
- Must parse complete JSON only after `content_block_stop`

### Vision/Image Support
**Image Content Block Format:**
```json
{
  "type": "image",
  "source": {
    "type": "base64",
    "media_type": "image/jpeg",
    "data": "iVBORw0KGgo..."
  }
}
```

**Supported media types:** `image/jpeg`, `image/png`, `image/gif`, `image/webp`

**Limits:**
- Max 20 images per request
- Max 3.75 MB per image
- Max 8000x8000 pixels per image
- Images only allowed in `user` role messages

**Implementation:** Convert existing attachment system to Anthropic image blocks. Validate media type matches actual image data to avoid API errors.

**Security:** Never log base64 `data` fields—only log metadata (media_type, size).

### Prompt Caching (Deferred to Post-MVP)
> Prompt caching adds request builder complexity without being core functionality. Implement after basic Anthropic support is working.

Prompt caching reduces costs by reusing prefixes. Add `cache_control` to cacheable content:

```json
{
  "system": [
    {"type": "text", "text": "...", "cache_control": {"type": "ephemeral"}}
  ]
}
```

**Key behaviors:**
- Default cache TTL: 5 minutes
- Extended cache (1 hour): Add beta header `extended-cache-ttl-2025-04-11`
- Thinking blocks cannot be cached directly with `cache_control`
- Changes to thinking parameters invalidate message cache breakpoints
- System prompts and tools remain cached despite thinking parameter changes

**Cost savings:** 90% reduction on cache reads for repeated prompts.

### Beta Headers
Pass via `anthropic-beta` header (comma-separated for multiple):

| Header | Feature | Notes |
|--------|---------|-------|
| `interleaved-thinking-2025-05-14` | Interleaved thinking | Claude 4 models only; `budget_tokens` can exceed `max_tokens` |
| `extended-cache-ttl-2025-04-11` | 1-hour cache duration | For long thinking sessions |
| `fine-grained-tool-streaming-2025-05-14` | Better tool streaming | Finer granularity in tool input deltas |

**Example:**
```
anthropic-beta: interleaved-thinking-2025-05-14,extended-cache-ttl-2025-04-11
```

### Interleaved Thinking (Claude 4+)
With interleaved thinking enabled, thinking blocks can occur multiple times within a turn (between tool calls). This differs from standard extended thinking where thinking appears only at the start.

**Request:**
```json
{
  "thinking": {"type": "enabled", "budget_tokens": 8192},
  "betas": ["interleaved-thinking-2025-05-14"]
}
```

**Stream handling:** Multiple `thinking` content blocks may appear throughout the response. Track block indices carefully.

### Token Counting (Future Enhancement)
Anthropic provides a token counting endpoint for pre-calculating costs:

**Endpoint:** `POST /v1/messages/count_tokens`

**Request:** Same structure as messages (model, messages, system, tools)

**Response:**
```json
{"input_tokens": 1234}
```

This is useful for:
- Cost estimation before sending requests
- Validating context length before hitting limits
- Analytics and usage tracking


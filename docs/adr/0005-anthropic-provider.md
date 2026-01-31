# ADR-0005: Anthropic Provider Architecture

**Date**: 2026-01-30
**Status**: Accepted
**Context**: Adding Anthropic (Claude) as a first-class AI provider with full feature parity

## Context

Anthropic's Claude models offer unique capabilities including:

- Extended thinking with interleaved thinking blocks
- Tool use with a different schema than OpenAI
- Server-Sent Events (SSE) streaming with a distinct event format
- Different authentication headers and API versioning

We needed to integrate Anthropic while:
1. Maintaining consistency with the existing multi-provider architecture (ADR-0001)
2. Supporting Anthropic-specific features (extended thinking, interleaved blocks)
3. Ensuring cross-platform compatibility (macOS, iOS, watchOS)
4. Providing resilience through retry logic and circuit breakers

## Decision

### 1. Separate Parser/Builder Components

Unlike OpenAI where parsing is inline, Anthropic uses dedicated components:

```
AnthropicProvider.swift      → Orchestrates requests and handles callbacks
AnthropicRequestBuilder.swift → Builds request payloads, validates images
AnthropicStreamParser.swift   → Parses SSE events, tracks block state
AnthropicEndpointResolver.swift → Resolves URLs with HTTPS enforcement
```

**Rationale**: Anthropic's SSE format requires stateful parsing (tracking multiple content blocks by index, accumulating tool JSON fragments). A dedicated parser class makes this state explicit and testable in isolation.

### 2. Content Block State Machine

The stream parser maintains state for interleaved content blocks:

```swift
struct AnthropicBlockState {
    let type: AnthropicContentBlockType  // text, thinking, tool_use
    var buffer: Data                      // For tool JSON accumulation
    var toolName: String?
    var toolId: String?
}

private var activeBlocks: [Int: AnthropicBlockState] = [:]
```

This supports Claude's interleaved thinking where thinking and text blocks can be interspersed in a single response.

### 3. Tool Format Conversion

Anthropic uses a different tool schema than OpenAI:

| OpenAI | Anthropic |
|--------|-----------|
| `type: "function"` | `type: "tool"` |
| `function.name` | `name` |
| `function.parameters` | `input_schema` |

The request builder converts OpenAI-format tools to Anthropic format, allowing the app to use a unified tool definition.

### 4. Circuit Breaker Integration

Anthropic requests use the same `NetworkCircuitBreaker` as other providers:

```swift
let circuitKey = NetworkCircuitBreaker.key(for: url, label: "anthropic.messages")
```

This prevents cascading failures during Anthropic outages and provides consistent retry behavior.

### 5. Image Validation

The request builder validates image attachments:

- Magic byte detection (JPEG, PNG, GIF, WebP)
- Size limit enforcement (3.75MB per image)
- Format verification before base64 encoding

### 6. Sendable Safety

Tool call inputs use `[String: AnyCodable]` instead of `[String: Any]` to ensure safe passage across actor boundaries:

```swift
struct AnthropicToolCall: Sendable {
    let id: String
    let name: String
    let input: [String: AnyCodable]
}
```

The parser is marked `@MainActor` to enforce single-threaded access to mutable state.

## Consequences

### Positive

1. **Full feature support**: Extended thinking, interleaved blocks, tool use all work
2. **Testability**: Each component (parser, builder, resolver) is independently testable
3. **Resilience**: Circuit breaker prevents cascading failures
4. **Type safety**: `AnyCodable` wrapper provides Sendable compliance
5. **Platform parity**: Works identically on macOS, iOS, and watchOS

### Negative

1. **More files**: Four files vs. OpenAI's two (provider + endpoint resolver)
2. **State complexity**: Parser maintains block state that must be carefully managed
3. **Conversion overhead**: Tool format conversion adds processing

### Neutral

1. **API versioning**: Uses `anthropic-version: 2023-06-01` header
2. **Beta features**: Interleaved thinking requires `anthropic-beta` header
3. **Error format**: Different error JSON structure, translated to `AynaError`

## Implementation Files

| File | Purpose |
|------|---------|
| [AnthropicProvider.swift](../../Core/Services/Providers/AnthropicProvider.swift) | Main provider implementation |
| [AnthropicRequestBuilder.swift](../../Core/Services/AnthropicRequestBuilder.swift) | Request payload construction |
| [AnthropicStreamParser.swift](../../Core/Services/AnthropicStreamParser.swift) | SSE event parsing |
| [AnthropicEndpointResolver.swift](../../Core/Services/AnthropicEndpointResolver.swift) | URL resolution |

## Test Coverage

| Test Suite | Coverage |
|------------|----------|
| `AnthropicProviderTests` | Provider integration, HTTP errors, cancellation |
| `AnthropicStreamParserTests` | SSE parsing, block state, tool use |
| `AnthropicRequestBuilderTests` | Request construction, image validation |
| `AnthropicEndpointResolverTests` | URL resolution, HTTPS enforcement |

## References

- [ADR-0001: Multi-Provider Architecture](./0001-multi-provider-architecture.md)
- [Anthropic API Documentation](https://docs.anthropic.com/en/api)
- [docs/architecture.md](../architecture.md) - Anthropic streaming event table
